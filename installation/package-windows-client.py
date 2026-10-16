#!/usr/bin/env python3
"""Package the Windows modular Engine with installed resources and native dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile

STAGING = []


def run(argv):
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed: {result.stderr or result.stdout}')
    return result.stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def closure(root, directories):
    system = Path(os.environ['SystemRoot']) / 'System32'
    queue = list((root / 'bin').glob('*.exe')) + list((root / 'bin').glob('*.dll')) + list((root / 'share/grammars').glob('*.dll'))
    seen = set()
    while queue:
        binary = queue.pop()
        if binary in seen:
            continue
        seen.add(binary)
        for name in re.findall(r'^\s+([\w.+-]+\.dll)\s*$', run(['dumpbin.exe', '/nologo', '/dependents', binary]), re.M | re.I):
            target = root / 'bin' / name
            if target.exists():
                queue.append(target)
                continue
            source = next((directory / name for directory in directories if (directory / name).is_file()), None)
            if source is None:
                if name.lower().startswith(('api-ms-win-', 'ext-ms-win-')) or (system / name).is_file():
                    continue
                raise ValueError(f'Unresolved native dependency {name} required by {binary.name}')
            shutil.copy2(source, target)
            queue.append(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', type=Path, required=True)
    args = parser.parse_args()
    if os.name != 'nt':
        raise ValueError('Build this package on its Windows target')
    config = json.loads(args.installation.read_text())
    if config['schema'] != 'laplace.modular-installation/v1' or config['host'].lower() != socket.gethostname().split('.')[0].lower():
        raise ValueError('Installation declaration does not select this Windows host')
    operator_sid = config['operator_client'].get('windows_sid', '')
    if not re.fullmatch(r'S-1-[0-9-]+', operator_sid):
        raise ValueError('Declare the Windows operator SID that reads the installed client')
    for key in ('prefix', 'build', 'engine', 'native', 'prepared', 'grammars', 'ucd', 'installed_config'):
        path = Path(config[key])
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError('Declare an absolute path for ' + key)
    revisions = {}
    for name, key in (('Laplace-Engine', 'engine'), ('Laplace-Native', 'native')):
        if run(['git', '-C', config[key], 'status', '--porcelain', '--untracked-files=no']):
            raise ValueError(name + ' has uncommitted changes; package exact source revisions')
        revisions[name] = run(['git', '-C', config[key], 'rev-parse', 'HEAD'])
    cache = (Path(config['build']) / 'CMakeCache.txt').read_text()
    for variable, key in (('CMAKE_HOME_DIRECTORY', 'engine'), ('LAPLACE_NATIVE', 'native')):
        selected = re.search(r'^' + variable + r':[^=]+=(.+)$', cache, re.M)
        if not selected or Path(selected.group(1).strip()).resolve() != Path(config[key]).resolve():
            raise ValueError('Configured build does not use the declared source: ' + variable)
    run(['cmake', '--build', config['build'], '--target', 'laplace_engine'])
    prefix = Path(config['prefix']).resolve()
    releases = prefix / 'releases'
    releases.mkdir(parents=True, exist_ok=True)
    candidate = Path(tempfile.mkdtemp(prefix='.package-', dir=releases)).resolve()
    if not candidate.is_relative_to(releases):
        raise ValueError('Package staging is outside the declared release directory')
    STAGING.append((candidate, releases))
    (candidate / 'bin').mkdir()
    shutil.copy2(Path(config['build']) / 'laplace.exe', candidate / 'bin/laplace.exe')
    shutil.copytree(Path(config['engine']) / 'recipes', candidate / 'share/recipes')
    shutil.copytree(Path(config['engine']) / 'firmware', candidate / 'share/firmware')
    shutil.copytree(config['prepared'], candidate / 'share/prepared')
    grammar_source = Path(config['grammars'])
    grammars = sorted(grammar_source.glob('*.dll'))
    if not grammars:
        raise ValueError('No compiled Windows grammars at the declared path')
    (candidate / 'share/grammars').mkdir()
    for file in grammars:
        shutil.copy2(file, candidate / 'share/grammars' / file.name)
    directories = [Path(path) for path in config['runtime_directories']]
    # oneMKL selects CPU kernels dynamically; these do not appear in PE imports.
    for pattern in config['mkl_runtime_libraries']:
        libraries = list(Path(config['mkl_runtime']).glob(pattern))
        if not libraries:
            raise ValueError('Missing declared oneMKL runtime library: ' + pattern)
        for file in libraries:
            shutil.copy2(file, candidate / 'bin' / file.name)
    closure(candidate, directories)
    files = {str(path.relative_to(candidate)).replace('\\', '/'): digest(path)
             for path in sorted(candidate.rglob('*')) if path.is_file()}
    package = {'schema': 'laplace.modular-package/v1', 'platform': 'windows-x86_64',
               'components': ['Laplace-Engine'], 'revisions': revisions, 'files': files,
               'grammars': [path.stem.removeprefix('libtree-sitter-') for path in grammars]}
    identity = hashlib.sha256(json.dumps(package, sort_keys=True).encode()).hexdigest()
    release = releases / identity
    (candidate / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
    if release.exists():
        if json.loads((release / 'package.json').read_text()) != package or any(digest(release / path) != value for path, value in files.items()):
            raise ValueError('Existing release bytes differ from its identity')
        shutil.rmtree(candidate)  # checked above: only this operation's private staging directory
    else:
        candidate.rename(release)
    # A private tempfile created while elevated can admit only the elevated
    # token. The operator's ordinary token must also read the published release.
    run(['icacls.exe', release, '/grant', '*' + operator_sid + ':(OI)(CI)(RX)'])
    if config.get('database_artifact_reader'):
        if config['socket'].lower() != socket.gethostname().lower() or not re.fullmatch(r'S-1-[0-9-]+', config['database_artifact_reader']):
            raise ValueError('A database artifact reader must select a Windows SID on the local database host')
        run(['icacls.exe', release / 'share/prepared', '/grant', '*' + config['database_artifact_reader'] + ':(OI)(CI)(RX)'])
    installed = {key: config[key] for key in ('schema', 'host', 'prefix', 'state', 'socket', 'port', 'database', 'threads', 'batch_mb', 'ucd')}
    installed.update(release=str(release), tier0=str(release / 'share/prepared/tier0.bin'),
                     flags=str(release / 'share/prepared/tier0.flags'), highway=str(release / 'share/prepared/tier0.highway'),
                     grammars=str(release / 'share/grammars'))
    destination = Path(config['installed_config'])
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        previous = json.loads(destination.read_text())
        if previous.get('schema') != config['schema'] or previous.get('host') != config['host']:
            raise ValueError('Installed configuration belongs to another application or host')
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent,
                                     prefix='.installation-', delete=False) as stream:
        pending = Path(stream.name)
        stream.write(json.dumps(installed, indent=2) + '\n')
    # Verify from the candidate installation without exposing the build PATH or
    # changing the selected command/configuration until native + SQL checks pass.
    profile = {'schema': 'laplace.modular-client/v1', 'installation': str(pending),
               'role': config['operator_client']['role'], 'data': config['operator_client']['data'],
               'work': config['operator_client']['work'], 'connection': config['operator_client']['connection']}
    import client
    client_candidate = pending.with_suffix('.client')
    client_candidate.write_text(json.dumps(profile))
    try:
        executable, environment, _ = client.selected(client_candidate)
        environment = client.process_environment(environment)
        environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
        for operation in (['text', 'Laplace'], ['status']):
            result = subprocess.run([str(executable), *operation], capture_output=True, text=True, env=environment, timeout=120)
            if result.returncode:
                raise ValueError('Packaged Engine ' + operation[0] + ' failed: ' + result.stderr)
            if operation == ['status'] and result.stdout.count("the same as this engine's") != 2:
                raise ValueError('Installed tier 0 and highway do not agree with the selected database: ' + result.stdout)
        os.replace(pending, destination)
    finally:
        client_candidate.unlink(missing_ok=True)
        pending.unlink(missing_ok=True)
    print(json.dumps({'release': str(release), 'installation': str(destination), 'files': len(files), 'grammars': len(grammars)}))


if __name__ == '__main__':
    try:
        main()
    finally:
        for path, parent in STAGING:
            if path.exists() and path.resolve().parent == parent.resolve() and path.name.startswith('.package-'):
                shutil.rmtree(path)
