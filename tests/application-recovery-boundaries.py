"""Live refusal checks for the recovery installer, against an explicit host declaration."""
import argparse
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', type=Path, required=True)
parser.add_argument('--target', required=True)
parser.add_argument('--script', type=Path, required=True)
args = parser.parse_args()
config = json.loads(args.configuration.read_text())[args.target]
archive = max((path for path in Path(config['archive-directory']).glob('*.dump')
               if '-' + config['source-database'] + '-' in path.name), key=lambda path: path.stat().st_mtime)


def databases():
    return subprocess.check_output(['runuser', '-u', config['pg-os-user'], '--', str(Path(config['pgbin']) / 'psql'),
                                    '-XAt', '-h', config['pgsocket'], '-p', str(config['pgport']), '-d', 'postgres',
                                    '-c', "SELECT datname FROM pg_database WHERE datname LIKE 'laplace_restore_%' ORDER BY datname"], text=True)


before = databases()
with tempfile.TemporaryDirectory(prefix='recovery-refusal-', dir=config['work-dir']) as directory:
    root = Path(directory)
    common = [sys.executable, str(args.script)]
    for key, value in config.items():
        if key not in ('host', 'archive-directory'):
            common.extend(['--' + key, str(value)])
    common.extend(['--output', str(root / 'receipt.json')])
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', int(config['api-port'])))
        listener.listen()
        result = subprocess.run(common + ['--archive', str(archive)], text=True, capture_output=True, timeout=15)
    if result.returncode == 0 or 'Address already in use' not in result.stderr:
        raise RuntimeError('Recovery did not reject an occupied API port')
    bad = root / 'corrupt.dump'
    shutil.copyfile(archive, bad)
    shutil.copyfile(str(archive) + '.sha256', str(bad) + '.sha256')
    with bad.open('r+b') as stream:
        stream.seek(-1, 2)
        stream.write(bytes([stream.read(1)[0] ^ 0xff]))
    result = subprocess.run(common + ['--archive', str(bad)], text=True, capture_output=True, timeout=15)
    if result.returncode == 0 or 'Backup checksum mismatch' not in result.stderr:
        raise RuntimeError('Recovery did not reject a corrupted backup')
    if databases() != before or (root / 'receipt.json').exists():
        raise RuntimeError('Rejected recovery changed database state or reported a successful receipt')
print(json.dumps({'occupied_port_rejected': True, 'corrupt_backup_rejected': True, 'database_state_unchanged': True}))
