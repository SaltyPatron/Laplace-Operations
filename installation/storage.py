#!/usr/bin/env python3
"""Collect owned Linux delivery outputs; never sweep source, data or archives."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def foreign_job_active(owner):
    if not owner:
        return False
    if owner.get('repository') == os.environ.get('GITHUB_REPOSITORY') and str(owner.get('run')) == os.environ.get('GITHUB_RUN_ID'):
        return False
    repository, run = owner.get('repository', ''), str(owner.get('run', ''))
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repository) or not run.isdigit():
        raise ValueError('Delivery work has an invalid ownership receipt')
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not token:
        return True
    request = urllib.request.Request('https://api.github.com/repos/' + repository + '/actions/runs/' + run,
                                     headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json'})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)['status'] != 'completed'
    except OSError:
        return True  # API/token visibility is not proof that another run ended.


def absolute(value):
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts or len(path.parts) < 3:
        raise ValueError('Cleanup needs a declared absolute output path: ' + str(path))
    return path


def contains(root, path):
    return path == root or root in path.parents


def json_file(path):
    return json.loads(path.read_text()) if path.is_file() else None


def recovery_pending(source):
    application = Path(os.environ.get('GITHUB_WORKSPACE', str(source / 'Laplace')))
    if not (application / 'app').is_dir():
        application = source if (source / 'app').is_dir() else source / 'Laplace'
    markers = [application / 'build' / name for name in (
        '.managed-publish-backup', '.api-publish-backup', '.application-publish-owner',
        '.application-restore-pending', '.uci-publish-pending', '.web-publish-pending')]
    markers.append(Path('/var/lib/laplace-managed/transaction.json'))
    return any(path.exists() or path.is_symlink() for path in markers)


def begin_delivery(site, source):
    if not os.environ.get('GITHUB_RUN_ID') or not os.environ.get('GITHUB_REPOSITORY'):
        raise ValueError('A delivery job must identify its GitHub run and repository')
    if site.is_symlink() or recovery_pending(source):
        raise ValueError('Recovery is pending; delivery work ownership was not changed')
    site.mkdir(parents=True, exist_ok=True)
    owner_file = site / '.delivery-owner.json'
    if owner_file.is_symlink() or foreign_job_active(json_file(owner_file)):
        raise ValueError('Another GitHub Actions run still owns delivery work')
    owner_file.write_text(json.dumps(dict(repository=os.environ['GITHUB_REPOSITORY'], run=os.environ['GITHUB_RUN_ID'])) + '\n')


def validate_tree(path, root):
    if path.parent != root:
        raise ValueError('Cleanup escaped its owning output directory: ' + str(path))
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError('Cleanup may not traverse a symlink: ' + str(ancestor))
    device = path.stat().st_dev
    for directory, children, files in os.walk(path, followlinks=False):
        if '.git' in children or '.git' in files:
            raise ValueError('Cleanup may not remove a source checkout: ' + str(path))
        if Path(directory).stat().st_dev != device:
            raise ValueError('Cleanup may not cross a mounted filesystem: ' + directory)


def process_references(prefix):
    """Use process identity, never a substring search of shell source text."""
    references, unknown = set(), False
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            name = (process / 'comm').read_text().strip()
            try:
                executable = (process / 'exe').resolve(strict=True)
                references.add(executable)
            except PermissionError:
                executable = None
            command = (process / 'cmdline').read_bytes().split(b'\0')
            for argument in command:
                value = os.fsdecode(argument)
                if value.startswith(str(prefix) + '/') and '\n' not in value:
                    references.add(Path(value).resolve())
            if name in ('lpm', 'laplace') and (executable is None or not contains(prefix, executable)):
                # An opaque native process could still map an older closure.
                unknown = unknown or executable is None
        except FileNotFoundError:
            continue  # process exited during the snapshot
        except PermissionError:
            unknown = True
    return references, unknown


def database_references(config):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    query = """SELECT pg_catalog.substr(setting,pg_catalog.strpos(setting,'=')+1)
FROM pg_catalog.pg_db_role_setting r CROSS JOIN LATERAL pg_catalog.unnest(r.setconfig) setting
WHERE pg_catalog.split_part(setting,'=',1) IN ('laplace.tier0','laplace.flags','laplace.highway')
UNION SELECT pg_catalog.current_setting(name,true) FROM
(VALUES ('laplace.tier0'),('laplace.flags'),('laplace.highway')) settings(name);"""
    role = (config.get('operator_client') or {}).get('role') or os.environ.get('LAPLACE_ROLE', 'laplace')
    command = [str(Path(config['pgbin']) / 'psql'), '-X', '-w', '-Atq', '-v', 'ON_ERROR_STOP=1',
               '-h', config['socket'], '-p', str(config['port']), '-U', role, '-d', 'postgres', '-c', query]
    if os.geteuid() == 0:
        command = ['runuser', '-u', config['pg_os_user'], '--', *command]
        command[command.index('-U') + 1] = config['pg_os_user']
    result = subprocess.run(command, capture_output=True, text=True,
                            env=dict(environment, PGCONNECT_TIMEOUT='10'), timeout=15)
    if result.returncode:
        raise ValueError('Database cache references are not observable; native releases are retained')
    return {Path(line) for line in result.stdout.splitlines() if line.startswith('/')}


def plan(work, build, source, site, modular=None, references=None, unknown=False, finish_job=False):
    work, build, source, site = map(absolute, (work, build, source, site))
    entries, notes = [], []
    references = set(references or ())
    # Staging spans several CI steps. It ends only after upload/receive/readback,
    # or at explicit operator cleanup, never at the end of an intermediate phase.
    recovery = recovery_pending(source)
    delivery_held = foreign_job_active(json_file(site / '.delivery-owner.json'))

    def add(path, root, kind, reasons=()):
        if path.exists() or path.is_symlink():
            reasons = list(reasons)
            if path.is_symlink():
                reasons.append('symlink')
            if any(contains(path, ref) for ref in references):
                reasons.append('live_reference')
            entries.append(dict(path=str(path), root=str(root), kind=kind, reasons=reasons, retire=not reasons))

    if finish_job:
        if not contains(work, site):
            raise ValueError('Site delivery work must stay within the declared work root')
        reasons = ['recovery_pending'] if recovery else []
        if delivery_held:
            reasons.append('another_ci_run')
        for name in ('stage', 'bundle'):
            add(site / name, site, 'delivery_work', reasons)

    if modular:
        prefix = absolute(modular['prefix'])
        releases = prefix / 'releases'
        current = prefix / 'current'
        selected = current.resolve(strict=True) if current.is_symlink() else None
        if selected is not None and selected.parent != releases:
            raise ValueError('Selected native release escaped its owner')
        if selected:
            references.add(selected)
        for key in ('tier0', 'flags', 'highway', 'grammars'):
            if modular.get(key):
                references.add(Path(modular[key]))
        rollback = 0
        for path in sorted(releases.iterdir() if releases.is_dir() else (), key=lambda p: p.stat().st_mtime, reverse=True):
            if not path.is_dir() or not re.fullmatch(r'[a-f0-9]{64}|\.package-[\w-]+', path.name):
                continue
            reasons = []
            if unknown or selected is None:
                reasons.append('reference_visibility_incomplete')
            held = any(contains(path, ref) for ref in references)
            if not held and not reasons and not path.name.startswith('.package-') and rollback < 1:
                reasons.append('rollback')
                rollback += 1
            # A hexadecimal directory is a release only with its package receipt.
            if not path.name.startswith('.package-') and not (path / 'package.json').is_file():
                reasons.append('unowned')
            add(path, releases, 'native_release', reasons)

    # Registered worktrees and current incremental profiles remain source owners.
    protected = {build / 'Laplace', build / 'Laplace-Engine', build / 'Laplace-postgres', build / 'modular-runtime'}
    source_roots = {source}
    if modular and modular.get('source'):
        source_roots.add(absolute(modular['source']))
    build_visibility = True
    repositories = set()
    for root in source_roots:
        try:
            if root.is_dir():
                repositories.update(root.iterdir())
            if (root / '.git').exists():
                repositories.add(root)
        except OSError:
            build_visibility = False
            notes.append('Builds retained: source registry is not readable at ' + str(root))
    for repository in repositories:
        if repository.name != 'Laplace' and not repository.name.startswith('Laplace-'):
            continue
        try:
            if not (repository / '.git').exists():
                continue
        except OSError:
            build_visibility = False
            notes.append('Builds retained: repository is not readable at ' + str(repository))
            continue
        result = subprocess.run(['git', '-c', 'safe.directory=' + str(repository), '-C', str(repository), 'worktree', 'list', '--porcelain'],
                                capture_output=True, text=True)
        if result.returncode:
            build_visibility = False
            notes.append('Builds retained: worktree registry unavailable for ' + str(repository))
            continue
        for line in result.stdout.splitlines():
            if line.startswith('worktree '):
                checkout = Path(line[9:])
                # Linux profiles may use the worktree name directly.
                protected.add(build / 'worktrees' / checkout.name)
                if checkout != repository:
                    identity = hashlib.sha256(str(checkout).lower().encode()).hexdigest()[:12]
                    protected.add(build / 'worktrees' / (checkout.name.lower() + '-' + identity))
    old_builds = build / 'worktrees'
    for path in old_builds.iterdir() if old_builds.is_dir() else ():
        if path.is_dir() and re.fullmatch(r'(?:wt-[\w.-]+|laplace-[a-f0-9]{12})', path.name):
            reasons = ['registered_build'] if any(contains(path, item) for item in protected) else []
            if not build_visibility:
                reasons.append('worktree_registry_incomplete')
            if any((Path(directory) / '.git').exists() for directory, _, _ in os.walk(path, followlinks=False)):
                reasons.append('source_checkout')
            add(path, old_builds, 'abandoned_build', reasons)
    return dict(schema='laplace.storage/v1', host=socket.gethostname(), run=os.environ.get('GITHUB_RUN_ID'),
                checked_utc=datetime.now(timezone.utc).isoformat(), entries=entries, notes=notes,
                recovery_pending=recovery, delivery_held=delivery_held,
                policy=dict(rollback_releases=1, source_data_archives='preserved',
                            incremental_profiles='preserved', recovery='preserved'))


@contextmanager
def host_lock(path):
    import fcntl
    path = absolute(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # site.sh, deploy.sh and modular.py already pass this same open description.
    try:
        inherited = os.fstat(8)
        same = (inherited.st_dev, inherited.st_ino) == (path.stat().st_dev, path.stat().st_ino)
    except (OSError, FileNotFoundError):
        same = False
    if same:
        fcntl.flock(8, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
        return
    if path.is_symlink() or path.with_name(path.name + '.turnstile').is_symlink():
        raise ValueError('Host lock may not be a symlink')
    wait = os.environ.get('LAPLACE_HOST_LOCK_WAIT_SECONDS', '0') or '0'
    if wait != 'wait' and not wait.isdigit():
        raise ValueError('Invalid host lock deadline')
    deadline = None if wait == 'wait' else time.monotonic() + int(wait)

    def acquire(stream):
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if deadline is not None and time.monotonic() >= deadline:
                    raise
                time.sleep(.1)

    with path.with_name(path.name + '.turnstile').open('a') as turnstile, path.open('a') as lock:
        acquire(turnstile)
        acquire(lock)
        fcntl.flock(turnstile, fcntl.LOCK_UN)
        yield


def collect(state):
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('This platform cannot safely collect directory trees')
    removed, devices = [], {}
    state.update(removed=removed, devices=devices)
    # Validate every target before mutating any of them.
    for entry in state['entries']:
        if entry['retire']:
            validate_tree(Path(entry['path']), Path(entry['root']))
    for entry in state['entries']:
        path = Path(entry['path'])
        if not entry['retire']:
            continue
        validate_tree(path, Path(entry['root']))
        device = path.stat().st_dev
        devices.setdefault(str(device), dict(path=str(path.parent), before=shutil.disk_usage(path).free))
        shutil.rmtree(path)
        removed.append(str(path))
    for device in devices.values():
        device['after'] = shutil.disk_usage(device['path']).free
    state.update(status='passed', removed=removed, devices=devices)
    return state


def cleanup_native(config, receipt):
    """Called by modular.py while its existing installation lock is still held."""
    work = Path(os.environ.get('LAPLACE_WORK', str(Path(config['receipts']).parents[1])))
    build = Path(os.environ.get('LAPLACE_BUILD', str(Path(config['build']).parent)))
    references, unknown = process_references(absolute(config['prefix']))
    notes = []
    try:
        references.update(database_references(config))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        unknown = True
        notes.append(str(error))
    state = plan(work, build, Path(config['source']), work / 'mono-site', config, references, unknown)
    state['notes'].extend(notes)
    try:
        collect(state)
    except Exception as error:
        state.update(status='failed', error=str(error))
        raise
    finally:
        Path(receipt).write_text(json.dumps(state, indent=2) + '\n')


def cleanup_managed(source):
    """Delegate leases, flat-payload rollback and privileged releases to their owner."""
    application = Path(os.environ.get('LAPLACE_APP_DIR', str(Path(os.environ.get('LAPLACE_INSTALL_PREFIX', '/opt/laplace')) / 'app')))
    if not application.is_dir():
        return 'not_installed'
    helper = Path('/usr/local/libexec/laplace-managed-deploy')
    if helper.is_file() and re.search(r'''["']prune-releases["']|prune-releases\)''', helper.read_text()):
        subprocess.run(['sudo', '-n', str(helper), 'prune-releases'], check=True, stdout=sys.stderr)
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', str(source / 'Laplace')))
    controller = workspace / 'deploy/linux/payload-sync.sh'
    if not controller.is_file():
        controller = source / 'Laplace/deploy/linux/payload-sync.sh'
    if not controller.is_file():
        return 'owner_unavailable'
    subprocess.run(['bash', '-c', 'source "$1"; laplace_prune_unreferenced_releases "$2"',
                    'storage-managed', str(controller), str(application)], check=True, stdout=sys.stderr)
    return 'passed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('begin', 'status', 'clean'))
    parser.add_argument('--finish-job', action='store_true', help='Retire completed/failed delivery staging, after all consumers')
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--modular-config', type=Path, default=Path('/etc/laplace/modular.json'))
    args = parser.parse_args()
    work = absolute(os.environ.get('LAPLACE_WORK', '/repos/work'))
    build = absolute(os.environ.get('LAPLACE_BUILD', '/repos/build'))
    source = absolute(os.environ.get('LAPLACE_SRC', '/repos/src'))
    site = absolute(os.environ.get('LAPLACE_SITE_WORK', str(work / 'mono-site')))
    config = json_file(args.modular_config)
    if config and config.get('host') != socket.gethostname().lower():
        raise ValueError('Modular cleanup declaration belongs to another host')
    if args.operation == 'clean' and socket.gethostname().lower() in ('hart-server', 'hart-prod', 'hart-cloud') and os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Hosted cleanup runs through the storage GitHub Actions workflow; local cleanup is for developer machines')
    receipt = args.receipt or work / 'operations' / ('storage-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json')
    lock = os.environ.get('LAPLACE_HOST_LOCK', os.environ.get('LAPLACE_LOCKS', str(work / 'locks')) + '/host-resource.lock')
    with host_lock(lock):
        if args.operation == 'begin':
            if not contains(work, site) or site.is_symlink():
                raise ValueError('Delivery work must use the declared work root')
            begin_delivery(site, source)
            print('Claimed delivery work: ' + str(site))
            return
        references, _ = process_references(site)
        unknown, notes = False, []
        if config:
            native_references, unknown = process_references(absolute(config['prefix']))
            references.update(native_references)
            try:
                references.update(database_references(config))
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                unknown = True
                notes.append(str(error))
        state = plan(work, build, source, site, config, references, unknown, args.finish_job)
        state['notes'].extend(notes)
        try:
            if args.operation == 'clean':
                collect(state)
                if state['recovery_pending'] or state['delivery_held'] or (site / 'stage').exists() or (site / 'bundle').exists():
                    state['managed_application'] = 'preserved_delivery_or_recovery'
                else:
                    state['managed_application'] = cleanup_managed(source)
                if args.finish_job and not any(entry['kind'] == 'delivery_work' and not entry['retire'] for entry in state['entries']):
                    owner_file = site / '.delivery-owner.json'
                    if owner_file.is_file() and not owner_file.is_symlink() and not foreign_job_active(json_file(owner_file)):
                        owner_file.unlink()
            else:
                state['status'] = 'audit'
        except Exception as error:
            state.update(status='failed', error=str(error))
            raise
        finally:
            receipt.parent.mkdir(parents=True, exist_ok=True)
            temporary = receipt.with_name(receipt.name + '.tmp')
            temporary.write_text(json.dumps(state, indent=2) + '\n')
            temporary.replace(receipt)
    print(json.dumps(dict(status=state['status'], receipt=str(receipt), removed=len(state.get('removed', [])),
                          retained=sum(not entry['retire'] for entry in state['entries']))))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Storage cleanup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
