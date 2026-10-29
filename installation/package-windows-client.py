#!/usr/bin/env python3
"""Package the Windows modular Engine with installed resources and native dependencies."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile

STAGING = []
STORE = None
DECLARATION = None
_spec = importlib.util.spec_from_file_location('artifact_store', Path(__file__).with_name('artifact_store.py'))
artifacts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(artifacts)


def stage_file(source, target):
    if STORE is None:
        return shutil.copy2(source, target)
    artifacts.materialize_file(source, target, STORE)
    return str(target)


def copy_prepared(source, destination):
    # Flags need their property layout. Highway identifier dumps and other
    # build diagnostics beside the caches are not runtime dependencies.
    destination.mkdir(parents=True)
    for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway'):
        stage_file(source / name, destination / name)


def verify_frozen_manifest(config, candidate):
    """Ask Native to reproduce the prepared Highway from its packaged inputs."""
    executable = candidate / 'bin/laplace.exe'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('LAPLACE_')}
    environment.update(LAPLACE_TIER0=str(candidate / 'share/prepared/tier0.bin'),
                       LAPLACE_MANIFEST=str(candidate / 'share/manifest'),
                       LAPLACE_CONNINFO='host=127.0.0.1 port=1 connect_timeout=1 dbname=unused')
    with tempfile.TemporaryDirectory(prefix='.highway-', dir=candidate) as temporary:
        generated = Path(temporary) / 'highway.bin'
        result = subprocess.run([str(executable), 'highway', '-o', str(generated)], env=environment,
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise ValueError('Packaged frozen manifests could not reproduce Highway: ' + result.stderr)
        fingerprints = []
        for path in (candidate / 'share/prepared/tier0.highway', generated):
            result = subprocess.run([str(executable), 'highway', '--fingerprint', '-o', str(path)],
                                    env=environment, capture_output=True, text=True, timeout=20)
            if result.returncode:
                raise ValueError('Native could not verify prepared Highway: ' + result.stderr)
            fingerprints.append(result.stdout.strip())
        if fingerprints[0] != fingerprints[1]:
            raise ValueError('Prepared Highway does not match the selected frozen manifests (' +
                             ' versus '.join(fingerprints) + '). Prepare it with this Engine and Native manifest before installation.')


def run(argv):
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed: {result.stderr or result.stdout}')
    return result.stdout.strip()


def ensure_release_access(config, release, operator_sid):
    """Hardlinked cache files need explicit readers, independent of any parent."""
    if not re.fullmatch(r'S-1-[0-9-]+', operator_sid):
        raise ValueError('Declare the Windows operator SID')
    reader = config.get('database_artifact_reader')
    if reader and (config['socket'].lower() != socket.gethostname().lower()
                   or not re.fullmatch(r'S-1-[0-9-]+', reader)):
        raise ValueError('A database artifact reader must select a Windows SID on the local database host')
    prepared = release / 'share/prepared'
    caches = [path for path in prepared.iterdir() if path.is_file()]
    if any(path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()) for path in (release, prepared, *caches)):
        raise ValueError('Installed cache access may not redirect through a link')
    run(['icacls.exe', release, '/grant', '*' + operator_sid + ':(OI)(CI)(F)'])
    if reader:
        run(['icacls.exe', prepared, '/grant', '*' + reader + ':(OI)(CI)(RX)'])
        # A publisher setting an ACL through another hardlink can replace
        # inherited ACEs with its own parent's rules. Explicit grants survive.
        for path in caches:
            run(['icacls.exe', path, '/grant', '*' + operator_sid + ':(F)', '*' + reader + ':(R)'])


def build_run(argv):
    # Build owners stream their own progress. Capturing an entire grammar build
    # hid minutes of work from the operator and discarded its useful live state.
    subprocess.run(list(map(str, argv)), check=True)


def runtime_binaries(config):
    if config.get('mcp'):
        root = Path(config['mcp_build'])
        return {'bin/laplace.exe': root / 'engine/laplace.exe',
                **{'bin/' + name: root / name for name in ('lpm.exe', 'lpm.dll')}}
    return {'bin/laplace.exe': Path(config['build']) / 'laplace.exe'}


def prepare_runtime(config, force=False):
    clean = ['--clean-first'] if force else []
    if config.get('mcp'):
        root = Path(config['mcp_build'])
        options = ['-UCMAKE_RUNTIME_OUTPUT_DIRECTORY', '-DLAPLACE_BUNDLE_ENGINE=ON',
                   '-DLAPLACE_INSTALL_RECIPE_RESOURCES=OFF',
                   '-DLAPLACE_ENGINE_SRC=' + (Path(config['engine']) / 'src').as_posix(),
                   '-DLAPLACE_NATIVE=' + Path(config['native']).as_posix()]
        if not (root / 'CMakeCache.txt').is_file():
            toolchain = Path(__file__).resolve().parent.parent / 'toolchain/laplace.cmake'
            options += ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(toolchain), '-DCMAKE_BUILD_TYPE=RelWithDebInfo']
        build_run(['cmake', '-S', config['mcp'], '-B', root, *options])
        build_run(['cmake', '--build', root, *clean, '--target', 'laplace_engine', 'lpm_program', 'lpm_lib'])
    else:
        cache = (Path(config['build']) / 'CMakeCache.txt').read_text()
        for variable, key in (('CMAKE_HOME_DIRECTORY', 'engine'), ('LAPLACE_NATIVE', 'native')):
            selected = re.search(r'^' + variable + r':[^=]+=(.+)$', cache, re.M)
            if not selected or Path(selected.group(1).strip()).resolve() != Path(config[key]).resolve():
                raise ValueError('Configured build does not use the declared source: ' + variable)
        build_run(['cmake', '--build', config['build'], *clean, '--target', 'laplace_engine'])


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def reusable_release(config, revisions):
    """Reuse only an intact release whose current build/resource inputs match.

    Revision strings alone do not cover generated binaries, caches, grammars or
    runtime dependencies. Check those bytes before avoiding another package copy.
    """
    try:
        installed = json.loads(Path(config['installed_config']).read_text())
        for key in ('schema', 'host', 'prefix', 'state', 'socket', 'port', 'database', 'threads', 'batch_mb', 'ucd'):
            if installed.get(key) != config[key]:
                return None
        release = Path(installed['release']).resolve(strict=True)
        if release.parent != (Path(config['prefix']) / 'releases').resolve():
            return None
        package = json.loads((release / 'package.json').read_text())
        if (package.get('schema') != 'laplace.modular-package/v1' or package.get('revisions') != revisions
                or package.get('frozen_manifest_verified') is not True
                or package.get('recipe_sources') != 'runtime-v1'
                or hashlib.sha256(json.dumps(package, sort_keys=True).encode()).hexdigest() != release.name):
            return None
        inputs = runtime_binaries(config)
        for root, target in ((Path(config['engine']) / 'recipes', 'share/recipes'),
                             (Path(config['engine']) / 'firmware', 'share/firmware'),
                             (Path(config['native']) / 'manifest', 'share/manifest')):
            inputs.update({target + '/' + file.relative_to(root).as_posix(): file for file in root.rglob('*')
                           if file.is_file() and not (target == 'share/recipes' and file.relative_to(root).as_posix().startswith('formats/grammars/'))})
        inputs.update({'share/prepared/' + name: Path(config['prepared']) / name
                       for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway')})
        grammars = sorted(Path(config['grammars']).glob('*.dll'))
        if not grammars:
            return None
        inputs.update({'share/grammars/' + file.name: file for file in grammars})
        for pattern in config['mkl_runtime_libraries']:
            files = list(Path(config['mkl_runtime']).glob(pattern))
            if not files:
                return None
            inputs.update({'bin/' + file.name: file for file in files})
        files = package['files']
        if inputs.keys() - files.keys():
            return None
        directories = [Path(path) for path in config['runtime_directories']]
        for relative, expected in files.items():
            if '..' in Path(relative).parts or Path(relative).is_absolute():
                return None
            source = inputs.get(relative)
            if source is None and relative.startswith('bin/') and Path(relative).suffix.lower() == '.dll':
                source = next((directory / Path(relative).name for directory in directories
                               if (directory / Path(relative).name).is_file()), None)
            if source is None or digest(source) != expected or digest(release / relative) != expected:
                return None
        return release
    except (OSError, ValueError, KeyError):
        return None


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
            stage_file(source, target)
            queue.append(target)


def main():
    global STORE, DECLARATION
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', type=Path, required=True)
    parser.add_argument('--force', action='store_true', help='Explicitly rebuild the selected native components and grammars')
    args = parser.parse_args()
    DECLARATION = args.installation.resolve()
    if os.name != 'nt':
        raise ValueError('Build this package on its Windows target')
    config = json.loads(args.installation.read_text())
    if config['schema'] != 'laplace.modular-installation/v1' or config['host'].lower() != socket.gethostname().split('.')[0].lower():
        raise ValueError('Installation declaration does not select this Windows host')
    STORE = Path(config.get('artifacts') or Path(config['prefix']) / 'artifacts')
    if not STORE.is_absolute() or '..' in STORE.parts:
        raise ValueError('Declare an absolute artifact store')
    operator_sid = config['operator_client'].get('windows_sid', '')
    if not re.fullmatch(r'S-1-[0-9-]+', operator_sid):
        raise ValueError('Declare the Windows operator SID that reads the installed client')
    for key in ('prefix', 'build', 'engine', 'native', 'prepared', 'grammars', 'ucd', 'installed_config'):
        path = Path(config[key])
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError('Declare an absolute path for ' + key)
    has_mcp = bool(config.get('mcp') and config.get('mcp_build'))
    if has_mcp:
        for key in ('mcp', 'mcp_build'):
            path = Path(config[key])
            if not path.is_absolute() or '..' in path.parts:
                raise ValueError('Declare an absolute path for ' + key)
    with artifacts.store_lock(STORE):
        revisions = {}
        repo_sources = [('Laplace-Engine', 'engine'), ('Laplace-Native', 'native')]
        if has_mcp:
            repo_sources.append(('Laplace-MCP', 'mcp'))
        for name, key in repo_sources:
            dirty = run(['git', '-C', config[key], 'status', '--porcelain', '--untracked-files=no'])
            head = run(['git', '-C', config[key], 'rev-parse', 'HEAD'])
            if dirty:
                diff_bytes = subprocess.run(['git', '-C', config[key], 'diff', 'HEAD'], capture_output=True, check=True).stdout
                revisions[name] = head + '-dirty-' + hashlib.sha256(diff_bytes).hexdigest()[:12]
            else:
                revisions[name] = head
        prepare_runtime(config, args.force)
        grammar_source = Path(config['grammars'])
        definitions = Path(config['engine']) / 'recipes/formats/grammars'
        if definitions.is_dir():
            builder = Path(__file__).resolve().parent / 'build-grammars.ps1'
            build_run(['pwsh', '-NoProfile', '-File', str(builder), '-Source', str(definitions),
                       '-Output', str(grammar_source), '-BuildDirectory', str(Path(config['mcp_build'] if has_mcp else config['build']) / 'grammars'),
                       *(['-Force'] if args.force else [])])
        reusable = reusable_release(config, revisions) if not args.force else None
        if reusable is not None:
            ensure_release_access(config, reusable, operator_sid)
            print(json.dumps({'release': str(reusable), 'reused': True, 'copied': 0,
                              'installation': str(config['installed_config']), 'revisions': revisions}))
            return
        prefix = Path(config['prefix']).resolve()
        releases = prefix / 'releases'
        releases.mkdir(parents=True, exist_ok=True)
        candidate = Path(tempfile.mkdtemp(prefix='.package-', dir=releases)).resolve()
        if not candidate.is_relative_to(releases):
            raise ValueError('Package staging is outside the declared release directory')
        STAGING.append((candidate, releases))
        (candidate / 'bin').mkdir()
        for relative, source in runtime_binaries(config).items():
            stage_file(source, candidate / relative)
        recipe_root = Path(config['engine']) / 'recipes'
        shutil.copytree(recipe_root, candidate / 'share/recipes', copy_function=stage_file,
                        ignore=lambda directory, names: ['grammars'] if Path(directory) == recipe_root / 'formats' else [])
        shutil.copytree(Path(config['engine']) / 'firmware', candidate / 'share/firmware', copy_function=stage_file)
        shutil.copytree(Path(config['native']) / 'manifest', candidate / 'share/manifest', copy_function=stage_file)
        copy_prepared(Path(config['prepared']), candidate / 'share/prepared')
        grammars = sorted(grammar_source.glob('*.dll'))
        if not grammars:
            raise ValueError('No compiled Windows grammars at the declared path')
        (candidate / 'share/grammars').mkdir()
        for file in grammars:
            stage_file(file, candidate / 'share/grammars' / file.name)
        directories = [Path(path) for path in config['runtime_directories']]
        # oneMKL selects CPU kernels dynamically; these do not appear in PE imports.
        for pattern in config['mkl_runtime_libraries']:
            libraries = list(Path(config['mkl_runtime']).glob(pattern))
            if not libraries:
                raise ValueError('Missing declared oneMKL runtime library: ' + pattern)
            for file in libraries:
                stage_file(file, candidate / 'bin' / file.name)
        closure(candidate, directories)
        verify_frozen_manifest(config, candidate)
        files = {str(path.relative_to(candidate)).replace('\\', '/'): digest(path)
                 for path in sorted(candidate.rglob('*')) if path.is_file()}
        components = ['Laplace-Engine']
        if has_mcp:
            components.append('Laplace-MCP')
        package = {'schema': 'laplace.modular-package/v1', 'platform': 'windows-x86_64',
                   'components': components, 'revisions': revisions, 'files': files, 'frozen_manifest_verified': True, 'recipe_sources': 'runtime-v1',
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
        ensure_release_access(config, release, operator_sid)
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
        profile.update({key: config['operator_client'][key] for key in ('source', 'models') if key in config['operator_client']})
        import client
        client_candidate = pending.with_suffix('.client')
        client_candidate.write_text(json.dumps(profile))
        try:
            executable, environment, _ = client.selected(client_candidate)
            environment = client.process_environment(environment)
            environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
            operations = [['text', 'Laplace'], ['status'], ['sources']]
            for operation in operations:
                result = subprocess.run([str(executable), *operation], capture_output=True, text=True, env=environment, timeout=120)
                if result.returncode:
                    raise ValueError('Packaged Engine ' + operation[0] + ' failed: ' + (result.stderr or result.stdout))
                if operation == ['sources'] and result.stderr.strip():
                    raise ValueError('Packaged recipe resources failed: ' + result.stderr)
                if operation == ['status'] and result.stdout.count("the same as this engine's") != 2:
                    raise ValueError('Installed tier 0 and highway do not agree with the selected database: ' + result.stdout)
            # The candidate MCP must initialize and execute a native tool before
            # changing the installed selection used by future client connections.
            if has_mcp:
                client.verify_mcp(executable, environment, database=config['database'])
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
        if STORE is not None:
            artifacts.cleanup(STORE, DECLARATION)
