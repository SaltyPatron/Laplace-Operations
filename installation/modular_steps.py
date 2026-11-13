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
    """Repair the installed release, or resume the last matching prepared install."""
    prefix = Path(config['prefix'])
    current = prefix / 'current'
    if current.is_symlink():
        release = current.resolve(strict=True)
    elif current.exists():
        raise ValueError('Active release path must be a symlink')
    else:
        release = None
        for prior in sorted(Path(config['receipts']).glob('*/package.json'), reverse=True):
            selection = prior.with_name('selection.json')
            if selection.is_file() and json.loads(selection.read_text()) == config:
                release = Path(json.loads(prior.read_text())['release'])
                break
        if release is None:
            return None
    if release.parent.resolve() != (prefix / 'releases').resolve() or release.is_symlink():
        raise ValueError('Prepared release is outside the declared installation')
    delivery = package_api(program)
    try:
        receipt = delivery.verify_package(release)
    except ValueError as error:
        if isinstance(error, getattr(delivery, 'PackageUpgradeRequired', ())):
            return None
        raise
    if 'libexec/laplace-mcp-deployment.py' not in receipt['files']:
        return None
    return {'release': str(release), 'package_id': release.name, 'revisions': receipt['revisions']}


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
    command = ['bash', '-c', '. "$1/laplace.env"; exec python3 "$2" package --config "$3" --output "$4" "${@:5}"',
               'modular-package', str(Path(config['source']) / 'Laplace-Operations'), str(program), str(config_path), str(receipt_path / 'package.json')]
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
START_FEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'


def web_unit_text(config):
    """The /modular host from the active release's web/, reading through the installed lpm with that unit's token."""
    web = Path(config['prefix']) / 'current/web'
    env = {'NativeEndpoint': f"http://127.0.0.1:{config['http_port']}", 'PathBase': config['web_path'],
           'Hosting': 'service', 'ASPNETCORE_URLS': f"http://127.0.0.1:{config['web_port']}", 'AllowedHosts': '*',
           'McpIdentityEndpoint': config['web_origin'].rstrip('/') + '/mcp', 'ReleaseId': 'modular',
           'DOTNET_NOLOGO': '1', 'DOTNET_CLI_TELEMETRY_OPTOUT': '1'}
    return ('[Unit]\nDescription=Laplace modular web host (' + config['web_path'] + ')\n'
            f'After=network-online.target {UNIT}\nWants={UNIT}\n\n[Service]\nType=simple\n'
            f"User={config['runtime_user']}\nGroup={config['runtime_group']}\n"
            + token_environment_line(config)
            + ''.join('Environment=' + sysquote(k + '=' + v) + '\n' for k, v in env.items())
            # WorkingDirectory takes a bare absolute path: systemd refuses a quoted one.
            + 'WorkingDirectory=' + str(web).replace('%', '%%') + '\n'
            + f'ExecStart=/usr/bin/dotnet {sysquote(web / "Laplace.Modular.Web.dll")}\n'
            'Restart=on-failure\nRestartSec=2\nUMask=0077\nNoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\n'
            'PrivateTmp=true\nPrivateDevices=true\nProtectKernelTunables=true\nProtectKernelModules=true\n'
            'ProtectControlGroups=true\nRestrictSUIDSGID=true\nCapabilityBoundingSet=\n'
            'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6\n\n[Install]\nWantedBy=multi-user.target\n')


def web_location_text(config):
    base = config['web_path'].rstrip('/')
    return (f'location = {base} {{ return 301 {base}/; }}\nlocation {base}/ {{\n'
            f"    proxy_pass http://127.0.0.1:{config['web_port']};\n    proxy_http_version 1.1;\n"
            '    proxy_set_header Host $host;\n    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
            '    proxy_set_header X-Forwarded-Proto $scheme;\n    proxy_read_timeout 300s;\n}\n')


def install_web(config):
    """Root, once per setup: the web unit and its nginx location. A deployment afterwards only restarts it."""
    if not WEB_LOCATION.parent.is_dir():
        raise ValueError('nginx has no ' + str(WEB_LOCATION.parent) + ': install the monorepo site first')
    prior = WEB_LOCATION.read_text() if WEB_LOCATION.exists() else None
    atomic(UNITS / WEB_UNIT, web_unit_text(config))
    checked(['systemd-analyze', 'verify', UNITS / WEB_UNIT], capture_output=True)
    checked(['systemctl', 'daemon-reload'])
    checked(['systemctl', 'enable', WEB_UNIT])
    checked(['systemctl', 'restart', WEB_UNIT])
    atomic(WEB_LOCATION, web_location_text(config))
    tested = checked(['nginx', '-t'], capture_output=True, check=False)
    if tested.returncode != 0:
        if prior is None:
            WEB_LOCATION.unlink()
        else:
            atomic(WEB_LOCATION, prior)
        raise ValueError('nginx refused the /modular location: ' + tested.stderr.strip()[-2000:])
    checked(['systemctl', 'reload', 'nginx'])


def verify_web(config, deadline_seconds=60):
    """The /modular host answers a chess position read with JSON from the database, not a page or an error."""
    import urllib.parse, urllib.request
    if not (UNITS / WEB_UNIT).is_file():
        raise ValueError('The /modular web host is not installed: sudo ./setup.sh modular')
    url = (f"http://127.0.0.1:{config['web_port']}{config['web_path'].rstrip('/')}/api/chess/position?"
           + urllib.parse.urlencode({'fen': START_FEN}))
    deadline, last = time.monotonic() + deadline_seconds, None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                kind = response.headers.get('Content-Type', '')
                body = json.load(response) if kind.startswith('application/json') else None
            if not isinstance(body, dict) or not isinstance(body.get('position'), str) or not isinstance(body.get('openings'), list):
                raise ValueError('The /modular chess read returned ' + (kind or 'no content type') + ', not a position')
            return {'url': url, 'position': body['position'], 'openings': len(body['openings']), 'games': body.get('games')}
        except (OSError, ValueError) as error:
            last = error
            time.sleep(1)
    raise ValueError('The /modular web host did not answer: ' + str(last))


def restart_units(config):
    root = UNITS
    name = 'laplace-modular-mcp-restart'
    signal = sysquote(config['restart_signal'])
    atomic(root / (name + '.path'), f"[Path]\nPathExists={config['restart_signal'].replace('%', '%%')}\n[Install]\nWantedBy=multi-user.target\n")
    # The web host runs from the same release (current/web); a release switch restarts both.
    atomic(root / (name + '.service'), '[Service]\nType=oneshot\n' +
        f'ExecStart=/usr/bin/rm -f -- {signal}\nExecStart=/usr/bin/systemctl restart {UNIT}\n'
        f'ExecStart=/usr/bin/systemctl try-restart {WEB_UNIT}\n')
    checked(['systemctl', 'daemon-reload'])
    checked(['systemctl', 'enable', '--now', name + '.path'])
