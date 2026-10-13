#!/usr/bin/env python3
"""Install the modular operator command without a runner checkout or sudo."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', type=Path, required=True)
    parser.add_argument('--role', required=True, help='Existing human database identity; never the MCP OS peer role')
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--command', type=Path, required=True)
    parser.add_argument('--connection', type=Path, help='JSON with non-secret libpq TLS/address options; credentials remain in the user store')
    parser.add_argument('--configuration', type=Path,
                        default=Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'laplace/client.json')
    args = parser.parse_args()
    for path in (args.installation, args.work, args.data, args.command, args.configuration):
        if not path.is_absolute() or '..' in path.parts or path == Path('/'):
            parser.error('Installation, work, command and configuration paths must be absolute')
    profile = {'schema': 'laplace.modular-client/v1', 'installation': str(args.installation),
               'role': args.role, 'work': str(args.work), 'data': str(args.data)}
    if args.connection:
        profile['connection'] = json.loads(args.connection.read_text())
    source = Path(__file__).with_name('client.py')
    spec = importlib.util.spec_from_file_location('client', source)
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)
    args.configuration.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=args.configuration.parent,
                                     prefix='.client-', suffix='.json', delete=False) as stream:
        candidate = Path(stream.name)
        stream.write(json.dumps(profile, indent=2) + '\n')
    pending = None
    try:
        executable, environment, _ = client.selected(candidate)
        # Native composition and selected-database readback precede command replacement.
        for operation in (['text', 'Laplace'], ['status']):
            verification = subprocess.run([str(executable), *operation],
                                          env=client.process_environment(environment), capture_output=True, text=True, timeout=60)
            if verification.returncode:
                raise ValueError('Installed modular Engine ' + operation[0] + ' failed: ' + verification.stderr.strip())
            if operation == ['status'] and verification.stdout.count("the same as this engine's") != 2:
                raise ValueError('Installed modular database must match both Engine artifact fingerprints: ' + verification.stdout.strip())
        if args.configuration.exists() and json.loads(args.configuration.read_text()).get('schema') != profile['schema']:
            raise ValueError('Refusing to replace a configuration belonging to another application')
        args.command.parent.mkdir(parents=True, exist_ok=True)
        # The command is self-contained and selects the declared client profile.
        program = source.read_text().replace("def main():\n", "def main():\n    os.environ.setdefault('LAPLACE_CLIENT_CONFIG', " + repr(str(args.configuration)) + ")\n", 1)
        with tempfile.NamedTemporaryFile(mode='w', dir=args.command.parent,
                                         prefix='.laplace-', delete=False) as stream:
            pending = Path(stream.name)
            if os.name == 'nt':
                if args.command.suffix.lower() != '.cmd':
                    raise ValueError('The Windows installed command must end in .cmd')
                # Persist the Python launcher alongside its script, using the
                # installed interpreter rather than a source/build environment.
                program_path = args.command.with_suffix('.py')
                with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=args.command.parent,
                                                 prefix='.laplace-program-', delete=False) as program_stream:
                    program_stream.write(program)
                    program_pending = Path(program_stream.name)
                try:
                    os.replace(program_pending, program_path)
                finally:
                    program_pending.unlink(missing_ok=True)
                stream.write('@"' + sys.executable.replace('%', '%%') + '" -I "%~dp0' + program_path.name + '" %*\n')
            else:
                stream.write(program)
        pending.chmod(0o755)
        os.replace(candidate, args.configuration)
        os.replace(pending, args.command)
    finally:
        candidate.unlink(missing_ok=True)
        if pending is not None:
            pending.unlink(missing_ok=True)
    print('Installed modular command: ' + str(args.command))
    subprocess.run([str(args.command), '--where'], check=True, timeout=10)


if __name__ == '__main__':
    main()
