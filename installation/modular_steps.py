#!/usr/bin/env python3
"""Release packaging, controller verification, and systemd activation steps for modular.py."""
import importlib.util
import json
import os
from pathlib import Path
try:
    import pwd
except ImportError:
    pwd = None
import shutil
import subprocess
import time
import uuid


def package_api(program):
    spec = importlib.util.spec_from_file_location('modular_package', program)
    delivery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(delivery)
    return delivery


def release_controller(config, release):
    delivery = package_api(Path(config['source']) / 'Laplace-MCP/deployment.py')
    receipt = delivery.verify_package(release)
    relative = 'libexec/laplace-mcp-deployment.py'
    if relative not in receipt['files']:
        raise ValueError('Modular package lacks its deployment controller; rebuild a compatible release')
    return Path(release) / relative


def prepared_package(config, program):
    """A verified package of this installation's checkouts that a deployment already prepared, else the installed
    release to repair; None when neither is usable and a package must be built."""
    prefix = Path(config['prefix'])
    current = prefix / 'current'
    if current.exists() and not current.is_symlink():
        raise ValueError('Active release path must be a symlink')
    delivery = package_api(program)

    def usable(release):
        if release.parent.resolve() != (prefix / 'releases').resolve() or release.is_symlink():
            raise ValueError('Prepared release is outside the declared installation')
        try:
            receipt = delivery.verify_package(release)
        except ValueError as error:
            if isinstance(error, getattr(delivery, 'PackageUpgradeRequired', ())):
                return None
            raise
        if 'libexec/laplace-mcp-deployment.py' not in receipt['files']:
            return None
        return {'release': str(release), 'package_id': release.name, 'revisions': receipt['revisions']}

    # A package is content addressed: one a staging deployment prepared (as the CI runner) from the same selection
    # and the same revisions is this one; only where its sources were checked out differs. So the selection is
    # compared without that, and the revisions it records against this installation's checkouts. The host's
    # installation then never rebuilds, as another account, what a deployment built in the tree that account owns.
    def selected(value):
        return {key: item for key, item in value.items() if key != 'source'}

    def revision(name):
        result = subprocess.run(['git', '-C', str(Path(config['source']) / name), 'rev-parse', 'HEAD'],
                                capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None

    for prior in sorted(Path(config['receipts']).glob('*/package.json'), reverse=True):
        selection = prior.with_name('selection.json')
        if not selection.is_file() or selected(json.loads(selection.read_text())) != selected(config):
            continue
        prepared = json.loads(prior.read_text())
        revisions = prepared.get('revisions') or {}
        if revisions and all(revision(name) == commit for name, commit in revisions.items()):
            found = usable(Path(prepared['release']))
            if found:
                return found
    return usable(current.resolve(strict=True)) if current.is_symlink() else None


def package(config, receipt_path, repair=False, rebuild=False):
    program = Path(config['source']) / 'Laplace-MCP/deployment.py'
    if repair:
        prepared = prepared_package(config, program)
        if prepared:
            atomic(receipt_path / 'selection.json', json.dumps(config) + '\n')
            atomic(receipt_path / 'package.json', json.dumps(prepared) + '\n')
            print('Reusing verified modular package: ' + prepared['package_id'], flush=True)
            return Path(prepared['release'])
    config_path = receipt_path / 'selection.json'
    atomic(config_path, json.dumps(config) + '\n')
    target_uid = pwd.getpwnam(config['operator']).pw_uid if os.geteuid() == 0 and pwd is not None else os.geteuid()
    inc = Path(config['build']) / 'incremental'
    if inc.exists() and inc.stat().st_uid != target_uid:
        user_build = Path(config['build']) / f'user-{target_uid}'
        user_build.mkdir(parents=True, exist_ok=True)
        shared_grammars = inc / 'grammars'
        user_grammars = user_build / 'incremental/grammars'
        if shared_grammars.is_dir() and not user_grammars.exists():
            shutil.copytree(shared_grammars, user_grammars, dirs_exist_ok=True)
        build_config = dict(config, build=str(user_build))
        build_config_path = receipt_path / 'build-selection.json'
        atomic(build_config_path, json.dumps(build_config) + '\n')
    else:
        build_config_path = config_path
    ts_cli = inc / 'deps/tree-sitter-cli/release/tree-sitter'
    command = [
        'bash', '-c',
        '. "$1/laplace.env"; '
        'export LAPLACE_DEPSRC="${LAPLACE_DEPSRC:-$LAPLACE_SRC}"; '
        'if [ -d "$LAPLACE_SRC/eigen" ]; then export LAPLACE_EIGEN_DIR="${LAPLACE_EIGEN_DIR:-$LAPLACE_SRC/eigen}"; '
        'elif [ -d /usr/include/eigen3 ]; then export LAPLACE_EIGEN_DIR="${LAPLACE_EIGEN_DIR:-/usr/include/eigen3}"; fi; '
        'if [ -d "$LAPLACE_SRC/spectra" ]; then export LAPLACE_SPECTRA_DIR="${LAPLACE_SPECTRA_DIR:-$LAPLACE_SRC/spectra}"; fi; '
        'if [ -n "$5" ] && [ -x "$5" ]; then export LAPLACE_TREESITTER_CLI="${LAPLACE_TREESITTER_CLI:-$5}"; fi; '
        'exec python3 "$2" package --config "$3" --output "$4" "${@:6}"',
        'modular-package',
        str(Path(config['source']) / 'Laplace-Operations'),
        str(program),
        str(build_config_path),
        str(receipt_path / 'package.json'),
        str(ts_cli) if ts_cli.is_file() else '',
    ]
    if rebuild:
        command.append('--clean-build')
    if os.geteuid() == 0:
        command = ['runuser', '-u', config['operator'], '--', *command]
    checked(command)
    return Path(json.loads((receipt_path / 'package.json').read_text())['release'])


def legacy_command(config, *arguments, check=True):
    user = pwd.getpwnam(config['legacy_user'])
    return subprocess.run(['runuser', '-u', user.pw_name, '--', 'env', 'XDG_RUNTIME_DIR=/run/user/' + str(user.pw_uid),
        'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + str(user.pw_uid) + '/bus',
        'systemctl', '--user', *arguments, config['legacy_unit']], text=True, capture_output=True, check=check)


def switch_link(path, target):
    if path.exists() and not path.is_symlink():
        raise ValueError('Active release path must be a symlink')
    temporary = path.with_name('.current-' + uuid.uuid4().hex)
    temporary.symlink_to(target, target_is_directory=True)
    os.replace(temporary, path)


def activate(config, release, receipt_path, install):
    if not install:
        program = release_controller(config, release)
        expected_environment = receipt_path / 'environment.expected'
        atomic(expected_environment, runtime_environment(package_api(program).runtime_environment(
            config, Path(config['prefix']) / 'current')), 0o640)
        checked(['bash', ROOT / 'installation/activate-modular.sh', receipt_path / 'selection.json',
                 release, receipt_path, UNITS / UNIT, expected_environment, '--',
                 'python3', program, 'verify', '--config', config['installed_config']], input=unit_text(config))
        return
    prefix = Path(config['prefix'])
    current = prefix / 'current'
    if release.parent.resolve() != (prefix / 'releases').resolve() or release.is_symlink():
        raise ValueError('Selected release is outside the declared release directory')
    previous = os.readlink(current) if current.is_symlink() else None
    program = release_controller(config, release)
    # The service environment points through current, so a release switch includes
    # Engine and recipes atomically and recurring deployment needs no root write.
    unit = UNITS / UNIT
    files = [unit, Path(config['environment_file'])]
    prior = {p: p.read_text() if p.exists() else None for p in files}
    legacy_active = install and legacy_command(config, 'is-active', check=False).returncode == 0
    old_active = subprocess.run(['systemctl', 'is-active', '--quiet', UNIT]).returncode == 0
    old_enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', UNIT], capture_output=True).returncode == 0
    previous_invocation = checked(['systemctl', 'show', UNIT, '-p', 'InvocationID', '--value'], capture_output=True, check=False).stdout.strip()
    # Candidate checks do not alter service configuration. A failed preflight
    # must not stop a service or try to restore a unit that was never installed.
    if install:
        peer_check(config)
        checked(['runuser', '-u', config['runtime_user'], '--', 'python3', program, 'probe',
                 '--config', config['installed_config'], '--release', release, '--output', Path(config['state']) / 'candidate.json'])
    try:
        if install:
            environment = runtime_environment(package_api(program).runtime_environment(config, current))
            atomic(unit, unit_text(config))
            atomic(config['environment_file'], environment)
            if not current.exists():
                switch_link(current, release)
            checked(['systemd-analyze', 'verify', unit], capture_output=True)
            checked(['systemctl', 'daemon-reload'])
            if legacy_active:
                legacy_command(config, 'stop')
        switch_link(current, release)
        if install:
            checked(['systemctl', 'enable', '--now', UNIT])
            checked(['systemctl', 'restart', UNIT])
        for _ in range(100):
            result = checked(['systemctl', 'show', UNIT, '-p', 'InvocationID', '-p', 'ActiveState'], capture_output=True)
            observed = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
            if observed.get('ActiveState') == 'active' and observed.get('InvocationID') and observed['InvocationID'] != previous_invocation:
                if unit.read_text() != unit_text(config):
                    raise ValueError('Installed service executable/configuration differs')
                break
            time.sleep(.2)
        else:
            raise ValueError('Service did not activate the selected executable')
        checked(['python3', program, 'verify', '--config', config['installed_config'], '--release', release,
                 '--output', receipt_path / 'runtime.json'])
        if install and legacy_active:
            legacy_command(config, 'disable')
    except BaseException:
        if previous:
            switch_link(current, previous)
        elif current.is_symlink():
            current.unlink()
        if install:
            if not old_enabled:
                checked(['systemctl', 'disable', '--now', UNIT], check=False, capture_output=True)
            for path, content in prior.items():
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic(path, content)
            checked(['systemctl', 'stop', UNIT], check=False, capture_output=True)
            checked(['systemctl', 'daemon-reload'])
            if old_active:
                checked(['systemctl', 'start', UNIT])
            if legacy_active:
                legacy_command(config, 'start')
        raise


WEB_UNIT = 'laplace-modular-web.service'
WEB_LOCATION = Path('/etc/nginx/laplace-mono/modular.location.conf')


def retire_web():
    """Root, idempotent: disable and remove the retired /modular web unit and nginx location if present."""
    unit_path = UNITS / WEB_UNIT
    unit_changed = False
    if unit_path.exists():
        checked(['systemctl', 'disable', '--now', WEB_UNIT], check=False, capture_output=True)
        unit_path.unlink()
        unit_changed = True
    if unit_changed:
        checked(['systemctl', 'daemon-reload'])
    if WEB_LOCATION.exists():
        prior = WEB_LOCATION.read_text()
        WEB_LOCATION.unlink()
        tested = checked(['nginx', '-t'], capture_output=True, check=False)
        if tested.returncode != 0:
            atomic(WEB_LOCATION, prior)
            raise ValueError('nginx refused removal of retired /modular location: ' + tested.stderr.strip()[-2000:])
        checked(['systemctl', 'reload', 'nginx'])


def restart_units(config):
    root = UNITS
    name = 'laplace-modular-mcp-restart'
    signal = sysquote(config['restart_signal'])
    atomic(root / (name + '.path'), f"[Path]\nPathExists={config['restart_signal'].replace('%', '%%')}\n[Install]\nWantedBy=multi-user.target\n")
    atomic(root / (name + '.service'), '[Service]\nType=oneshot\n' +
        f'ExecStart=/usr/bin/rm -f -- {signal}\nExecStart=/usr/bin/systemctl restart {UNIT}\n')
    checked(['systemctl', 'daemon-reload'])
    checked(['systemctl', 'enable', '--now', name + '.path'])
