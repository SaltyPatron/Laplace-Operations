#!/usr/bin/env python3
"""Install and deploy the declared modular service, independently of the monorepo MCP."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import grp
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
UNIT = 'laplace-modular-mcp.service'
UNITS = Path('/etc/systemd/system')


def checked(command, **kwargs):
    kwargs.setdefault('check', True)
    try:
        return subprocess.run([str(v) for v in command], text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr.strip()[-4000:], file=sys.stderr)
        raise


def config_load(path):
    config = json.loads(Path(path).read_text())
    if config.get('schema') != 'laplace.modular-installation/v1' or config['host'] != socket.gethostname().lower():
        raise ValueError('Modular declaration does not identify this host')
    for key in ('source', 'build', 'prefix', 'state', 'installed_config', 'environment_file', 'lock',
                'restart_signal', 'receipts', 'tier0', 'flags', 'highway', 'grammars', 'ucd', 'pgbin', 'pgdata', 'socket'):
        value = config[key]
        if not isinstance(value, str) or not Path(value).is_absolute() or '..' in Path(value).parts or len(Path(value).parts) < 2 or any(c in value for c in '\n\r\0'):
            raise ValueError('Invalid modular path: ' + key)
    for key in ('operator', 'runtime_user', 'runtime_group', 'role', 'database', 'pg_os_user', 'deployment_group', 'legacy_user'):
        if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,62}', config[key]):
            raise ValueError('Invalid modular identity: ' + key)
    if config['runtime_user'] in (config['operator'], config['pg_os_user'], 'root', 'laplace-runner'):
        raise ValueError('Runtime identity must be independent of operator, deployer and database administrator')
    for key in ('threads', 'build_jobs', 'connection_limit', 'batch_mb', 'http_port', 'port'):
        if type(config[key]) is not int or config[key] <= 0:
            raise ValueError('Invalid modular allocation: ' + key)
    if config['bind'] != '127.0.0.1' or max(config['http_port'], config['port']) > 65535:
        raise ValueError('Invalid listener declaration')
    if config['connection_limit'] < 3 * config['threads'] + 2:
        raise ValueError('Connection allocation cannot fit the resident reader and Engine bulk writer')
    client = config.get('operator_client')
    if client:
        for key in ('work', 'data', 'command', 'configuration', *[k for k in ('source', 'models') if k in client]):
            path = Path(client[key])
            if not path.is_absolute() or '..' in path.parts or path == Path('/'):
                raise ValueError('Invalid operator client path: ' + key)
        if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,62}', client['role']) or client['role'] == config['role']:
            raise ValueError('Operator client must name its own database identity')
    for key in ('postgres_service', 'legacy_unit'):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+\.service', config[key]):
            raise ValueError('Invalid service name')
    prefix, state, build = (Path(config[k]) for k in ('prefix', 'state', 'build'))
    for a, b in ((prefix, state), (prefix, build), (state, build)):
        if a.is_relative_to(b) or b.is_relative_to(a):
            raise ValueError('Build, release and writable runtime state must be independent')
    pg_socket = "'" + config['socket'].replace('\\', '\\\\').replace("'", "\\'") + "'"
    config['connection'] = f"host={pg_socket} port={config['port']} dbname={config['database']} user={config['role']}"
    return config


def select_manifest():
    import importlib.util
    spec = importlib.util.spec_from_file_location('machine_env', ROOT / 'machine-env.py')
    machine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(machine)
    declared = machine.resolve(Path(os.environ.get('LAPLACE_MACHINE_ENV') or '/etc/laplace/machine.env'), os.environ)
    supplied = os.environ.get('LAPLACE_MODULAR_MANIFEST') or declared.get('LAPLACE_MODULAR_MANIFEST')
    path = Path(supplied) if supplied else ROOT / 'installation' / (socket.gethostname().lower() + '-modular.json')
    if supplied or path.exists():
        config_load(path)
        return path
    return None


def atomic(path, text, mode=0o644):
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Refusing linked configuration destination: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sysquote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def token_file(config):
    """The service's bearer token, beside its environment as the monorepo MCP's secrets/mcp.env is."""
    return Path(config['environment_file']).parent / 'secrets/modular-mcp.env'


def provision_token(config):
    """Make the listener's token once (64 hex, root:deployment group 0640) and never replace it.

    lpm serve refuses to listen without it; the deployment verification reads it through the group."""
    path = token_file(config)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Refusing linked credential destination: ' + str(path))
    gid = grp.getgrnam(config['deployment_group']).gr_gid
    if not path.parent.is_dir():
        path.parent.mkdir(parents=True)
        os.chown(path.parent, 0, gid)
        path.parent.chmod(0o750)
    if path.exists():
        if not re.fullmatch(r'LAPLACE_MCP_TOKEN="[0-9a-f]{64}"\n', path.read_text()):
            raise ValueError('Installed MCP token is malformed; explicit rotation required: ' + str(path))
    else:
        atomic(path, 'LAPLACE_MCP_TOKEN="' + secrets.token_hex(32) + '"\n', 0o640)
    os.chown(path, 0, gid)
    path.chmod(0o640)
    return path


HELPER = 'laplace-modular-credential'
HELPER_PROGRAM = Path('/usr/local/libexec/laplace-modular.py')
HELPER_BIN = Path('/usr/local/sbin/laplace-modular-credential')


def credential_signal(config):
    return Path(config['restart_signal']).with_name('converge-modular-credential')


def token_environment_line(config):
    return 'EnvironmentFile=' + str(token_file(config)).replace('%', '%%') + '\n'


def with_token_environment(text, config):
    """Name the token file beside the declared environment file, once."""
    line = token_environment_line(config)
    if line in text:
        return text
    env = 'EnvironmentFile=' + config['environment_file'].replace('%', '%%') + '\n'
    if env not in text:
        raise ValueError('Service template names no environment file')
    return text.replace(env, env + line, 1)


def unit_text(config):
    template = (Path(config['source']) / 'Laplace-MCP/laplace-modular-mcp.service.in').read_text()
    text = template.format(user=config['runtime_user'], group=config['runtime_group'],
        postgres_service=config['postgres_service'], environment_file=config['environment_file'].replace('%', '%%'),
        state=config['state'].replace('%', '%%'), writable_state=sysquote(config['state']),
        executable=sysquote(Path(config['prefix']) / 'current/bin/lpm'))
    # systemd reads the token as root; the runtime account never sees the file. The file is declared
    # installation state: setup, install and repair make it once and name it here. Until that file
    # exists the rendered unit is the one already installed, so a deployment still matches it.
    if token_file(config).is_file():
        text = with_token_environment(text, config)
    return text


def credential_well_formed(config):
    path = token_file(config)
    if not path.is_file():
        return False
    try:
        text = path.read_text()
    except OSError:
        return False
    return re.fullmatch(r'LAPLACE_MCP_TOKEN="[0-9a-f]{64}"\n', text) is not None


def listener_credential_ready(config):
    unit = UNITS / UNIT
    return credential_well_formed(config) and unit.is_file() and token_environment_line(config) in unit.read_text()


def converge_listener_credential(config):
    """Make the listener token once and name it on the installed unit. A later call changes nothing.

    This does not restart the service. Deployment's existing restart loads the unit after this."""
    if os.geteuid() != 0:
        raise ValueError('The listener credential is installed by setup')
    provision_token(config)
    unit = UNITS / UNIT
    if not unit.is_file():
        return token_file(config)
    current = unit.read_text()
    desired = with_token_environment(current, config)
    if desired != current:
        atomic(unit, desired)
        checked(['systemctl', 'daemon-reload'])
    return token_file(config)


def install_credential_helper(config):
    """Install the one root action a deployment may ask for: converge the listener credential.

    The program is root's copy. The runner writes a signal; it does not get sudo and it does not
    choose the program that runs."""
    if os.geteuid() != 0:
        raise ValueError('The listener credential helper is installed by setup')
    atomic(HELPER_PROGRAM, Path(__file__).read_text(), 0o755)
    os.chown(HELPER_PROGRAM, 0, 0)
    # The installed copy has no checkout, so the declaration's installed_config is the only input.
    atomic(HELPER_BIN, '#!/bin/sh\nexec python3 /usr/local/libexec/laplace-modular.py converge '
           + shlex.quote(config['installed_config']) + '\n', 0o755)
    os.chown(HELPER_BIN, 0, 0)
    signal = str(credential_signal(config)).replace('%', '%%')
    atomic(UNITS / (HELPER + '.service'), '[Unit]\nDescription=Converge the modular listener credential\n[Service]\nType=oneshot\n'
        'ExecStart=/usr/local/sbin/laplace-modular-credential\n')
    atomic(UNITS / (HELPER + '.path'), '[Unit]\nDescription=Deployment asks for the modular listener credential\n'
        '[Path]\nPathChanged=' + signal + '\n[Install]\nWantedBy=multi-user.target\n')
    checked(['systemctl', 'daemon-reload'])
    checked(['systemctl', 'enable', '--now', HELPER + '.path'])


def systemctl_show(unit, *properties):
    result = checked(['systemctl', 'show', unit, *[item for prop in properties for item in ('-p', prop)]],
                     capture_output=True, check=False)
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


def converge_operation(config_path=None):
    """Root entry for setup and for the installed helper.

    A checkout run selects this host's declaration, installs the helper aimed at that
    declaration's installed_config, then converges. The helper's own run loads the path it was
    given and only converges, so asking it cannot replace the program it is executing."""
    if os.geteuid() != 0:
        raise ValueError('The listener credential is installed by setup')
    if config_path is None:
        manifest = select_manifest()
        if manifest is None:
            raise ValueError('No modular runtime declared for this host')
        config = config_load(manifest)
    else:
        config = config_load(Path(config_path))
    if Path(__file__).resolve() != HELPER_PROGRAM.resolve():
        install_credential_helper(config)
    return converge_listener_credential(config)


def ensure_listener_credential(config):
    """Deployment does not create the credential and does not take sudo. It asks the helper setup installed."""
    if listener_credential_ready(config):
        return
    if os.geteuid() == 0:
        converge_listener_credential(config)
        return
    if subprocess.run(['systemctl', 'is-active', '--quiet', HELPER + '.path']).returncode != 0:
        raise ValueError('The listener credential is not installed: ' + str(token_file(config)))
    before = systemctl_show(HELPER + '.service', 'ExecMainStartTimestamp').get('ExecMainStartTimestamp', '')
    credential_signal(config).write_text(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ') + '\n')
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        observed = systemctl_show(HELPER + '.service', 'ActiveState', 'Result', 'ExecMainStartTimestamp')
        started = observed.get('ExecMainStartTimestamp', '')
        if started and started != before and observed.get('ActiveState') in ('inactive', 'dead'):
            if observed.get('Result') != 'success' or not listener_credential_ready(config):
                raise ValueError('The listener credential convergence failed: ' + str(token_file(config)))
            return
        time.sleep(0.2)
    raise ValueError('The listener credential was not converged: ' + str(token_file(config)))


def runtime_environment(config, release):
    values = {'LAPLACE_CONNINFO': config['connection'], 'LAPLACE_TIER0': config['tier0'],
        'LAPLACE_FLAGS': config['flags'], 'LAPLACE_HIGHWAY': config['highway'], 'LAPLACE_GRAMMARS': config['grammars'],
        'LAPLACE_UCD': config['ucd'], 'LAPLACE_WORK': config['state'], 'LAPLACE_ENGINE': str(release / 'bin/laplace'),
        'LAPLACE_RECIPES': str(release / 'share/recipes'), 'LAPLACE_MCP_HOST': config['bind'],
        'LAPLACE_MCP_PORT': str(config['http_port']), 'OMP_NUM_THREADS': str(config['threads']),
        'MKL_NUM_THREADS': '1', 'LAPLACE_BATCH_MB': str(config['batch_mb'])}
    # EnvironmentFile does not expand shell/systemd specifiers in values.
    return ''.join(k + '=' + '"' + v.replace('\\', '\\\\').replace('"', '\\"') + '"\n' for k, v in values.items())


@contextmanager
def host_lock(config):
    old = os.umask(0o002)
    try:
        descriptor = os.open(config['lock'], os.O_WRONLY | os.O_CREAT, 0o660)
    finally:
        os.umask(old)
    turnstile = None
    try:
        # As operation-lock.sh: try once, then wait up to LAPLACE_HOST_LOCK_WAIT_SECONDS (default 0, immediate refusal;
        # CI selects 'wait' to follow actual holder release) for another repository's host operation. And as it, through
        # the turnstile (the lock's path with .turnstile), held while this waits for the lock: readers that come after
        # do not get in ahead of this deployment (flock grants a new shared holder past a waiting exclusive one).
        wait = os.environ.get('LAPLACE_HOST_LOCK_WAIT_SECONDS', '0') or '0'
        if wait != 'wait' and not wait.isdigit():
            raise ValueError('LAPLACE_HOST_LOCK_WAIT_SECONDS must be a nonnegative integer or wait')
        deadline = None if wait == 'wait' else time.monotonic() + int(wait)
        old = os.umask(0o002)
        try:
            turnstile = os.open(config['lock'] + '.turnstile', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o660)
        finally:
            os.umask(old)
        waiting = False
        for held in (turnstile, descriptor):
            while True:
                try:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if deadline is not None and time.monotonic() >= deadline:
                        raise ValueError('host lock deadline expired: ' + config['lock'] + '; no shared-runtime changes performed')
                    if not waiting:
                        duration = '' if deadline is None else 'up to ' + wait + 's '
                        print('Waiting ' + duration + 'for ' + config['lock'] + ' (exclusive)', file=sys.stderr, flush=True)
                        waiting = True
                    time.sleep(0.2 if deadline is None else min(0.2, max(0.0, deadline - time.monotonic())))
        os.close(turnstile)
        turnstile = None
        yield
    finally:
        if turnstile is not None:
            os.close(turnstile)
        os.close(descriptor)


def sql(config, statement):
    psql = [Path(config['pgbin']) / 'psql', '-XwAt', '-v', 'ON_ERROR_STOP=1',
            '-h', config['socket'], '-p', config['port'], '-d', config['database'], '-f', '-']
    if os.geteuid() == 0:
        command = ['runuser', '-u', config['pg_os_user'], '--', *psql]
    else:
        operator_role = (config.get('operator_client') or {}).get('role') or os.environ.get('LAPLACE_ROLE') or 'laplace'
        command = [*psql[:-2], '-U', operator_role, '-f', '-']
    return checked(command, input=statement, capture_output=True).stdout.strip()


def grants(config):
    role, database = config['role'], config['database']
    return f'''BEGIN;
DO $$ BEGIN
 IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='{role}') THEN CREATE ROLE "{role}" LOGIN; END IF;
 IF EXISTS (SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='{role}')) THEN
  RAISE EXCEPTION 'Dedicated modular role already has memberships'; END IF;
END $$;
ALTER ROLE "{role}" NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT {config['connection_limit']};
GRANT CONNECT,TEMPORARY ON DATABASE "{database}" TO "{role}";
GRANT SET ON PARAMETER session_replication_role TO "{role}";
GRANT USAGE ON SCHEMA public TO "{role}";
GRANT EXECUTE ON FUNCTION public.laplace_clean_pending_list(regclass) TO "{role}";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{role}";
CREATE SCHEMA IF NOT EXISTS stage;
GRANT USAGE,CREATE ON SCHEMA stage TO "{role}";
GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,MAINTAIN ON ALL TABLES IN SCHEMA stage TO "{role}";
DO $$ DECLARE item record; BEGIN
 FOR item IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p')
   AND c.relname ~ '^(entity|physicality|consensus)(_[0-9a-f]{{1,2}})?$|^witness$'
 LOOP EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,MAINTAIN ON TABLE public.%I TO "{role}"',item.relname); END LOOP;
END $$;
COMMIT;
'''


def include_file(path, line):
    text = path.read_text()
    if line not in text.splitlines():
        atomic(path, text.rstrip() + '\n' + line + '\n', 0o600)


def prepare(config):
    if sql(config, 'SHOW data_directory;') != config['pgdata']:
        raise ValueError('Connected PostgreSQL cluster differs from the installation')
    try:
        runtime = pwd.getpwnam(config['runtime_user'])
    except KeyError:
        checked(['useradd', '--system', '--user-group', '--home-dir', config['state'], '--no-create-home',
                 '--shell', '/usr/sbin/nologin', config['runtime_user']])
        runtime = pwd.getpwnam(config['runtime_user'])
    if runtime.pw_uid == 0 or grp.getgrgid(runtime.pw_gid).gr_name != config['runtime_group']:
        raise ValueError('Runtime account differs from its declaration')
    operator = pwd.getpwnam(config['operator'])
    deploy_gid = grp.getgrnam(config['deployment_group']).gr_gid
    for key, uid, gid, mode in (('prefix', operator.pw_uid, deploy_gid, 0o2775),
                               ('build', operator.pw_uid, deploy_gid, 0o2775),
                               ('receipts', operator.pw_uid, deploy_gid, 0o2775),
                               ('state', runtime.pw_uid, runtime.pw_gid, 0o700)):
        path = Path(config[key])
        if any(p.is_symlink() for p in (path, *path.parents)):
            raise ValueError('Installation directory traverses a link: ' + key)
        path.mkdir(parents=True, exist_ok=True)
        os.chown(path, uid, gid)
        path.chmod(mode)
    sql(config, grants(config))
    pgdata = Path(config['pgdata'])
    atomic(pgdata / 'pg_hba.modular.conf', f"local {config['database']} {config['role']} peer map=laplace_modular\nlocal all {config['role']} reject\nhost all {config['role']} 0.0.0.0/0 reject\nhost all {config['role']} ::0/0 reject\n", 0o644)
    atomic(pgdata / 'pg_ident.modular.conf', f"laplace_modular {config['runtime_user']} {config['role']}\n", 0o644)
    include_file(pgdata / 'pg_hba.conf', 'include_if_exists pg_hba.modular.conf')
    include_file(pgdata / 'pg_ident.conf', 'include_if_exists pg_ident.modular.conf')
    # Keep administrator configuration ownership when replacing files atomically.
    postgres = pwd.getpwnam(config['pg_os_user'])
    for name in ('pg_hba.conf', 'pg_ident.conf'):
        os.chown(pgdata / name, postgres.pw_uid, postgres.pw_gid)
    if sql(config, 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;') != '0':
        raise ValueError('PostgreSQL authentication configuration is invalid')
    sql(config, 'SELECT pg_reload_conf();')
    atomic(config['installed_config'], json.dumps(config, indent=2) + '\n')


def peer_check(config):
    command = ['runuser', '-u', config['runtime_user'], '--', Path(config['pgbin']) / 'psql',
               '-XwAt', '-v', 'ON_ERROR_STOP=1', '-h', config['socket'], '-p', config['port'], '-U', config['role']]
    output = checked(command + ['-d', config['database'], '-c',
        "SELECT current_user; SELECT extversion FROM pg_extension WHERE extname='laplace'; SELECT count(*) FROM public.entity WHERE id='5b7e40e9a23ae55eaccd45646934977d'::blake3;"], capture_output=True).stdout
    if output.splitlines()[0] != config['role']:
        raise ValueError('Peer runtime database identity differs')
    for database, statement in ((config['database'], 'SET ROLE laplace;'),
                                (config['database'], 'BEGIN; CREATE TABLE public.modular_boundary_probe(id int); ROLLBACK;'),
                                ('postgres', 'SELECT 1;')):
        result = checked(command + ['-d', database, '-c', statement], capture_output=True, check=False)
        if result.returncode == 0:
            raise ValueError('Runtime database privilege boundary was not enforced')


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


def package(config, receipt_path, repair=False):
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
    command = ['bash', '-c', '. "$1/laplace.env"; exec python3 "$2" package --config "$3" --output "$4"',
               'modular-package', str(Path(config['source']) / 'Laplace-Operations'), str(program), str(config_path), str(receipt_path / 'package.json')]
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
    prefix = Path(config['prefix'])
    current = prefix / 'current'
    if release.parent.resolve() != (prefix / 'releases').resolve() or release.is_symlink():
        raise ValueError('Selected release is outside the declared release directory')
    previous = os.readlink(current) if current.is_symlink() else None
    program = release_controller(config, release)
    # The service environment points through current, so a release switch includes
    # Engine and recipes atomically and recurring deployment needs no root write.
    environment = runtime_environment(config, current)
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
        else:
            Path(config['restart_signal']).touch()
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
        elif previous:
            Path(config['restart_signal']).touch()
        raise


def restart_units(config):
    root = UNITS
    name = 'laplace-modular-mcp-restart'
    signal = sysquote(config['restart_signal'])
    atomic(root / (name + '.path'), f"[Path]\nPathExists={config['restart_signal'].replace('%', '%%')}\n[Install]\nWantedBy=multi-user.target\n")
    atomic(root / (name + '.service'), '[Service]\nType=oneshot\n' +
        f'ExecStart=/usr/bin/rm -f -- {signal}\nExecStart=/usr/bin/systemctl restart {UNIT}\n')
    checked(['systemctl', 'daemon-reload'])
    checked(['systemctl', 'enable', '--now', name + '.path'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('install', 'deploy', 'check', 'select', 'converge'))
    parser.add_argument('config', nargs='?', help='Installed declaration for converge; a checkout run selects the host declaration')
    parser.add_argument('--manifest')
    parser.add_argument('--source')
    args = parser.parse_args()
    # The installed helper is a root-owned copy of this file. It converges the declaration path
    # setup wrote into it, and must not load this checkout (that copy's directory is /usr/local/libexec).
    if args.operation == 'converge':
        converge_operation(args.config)
        return
    manifest = Path(args.manifest) if args.manifest else select_manifest()
    if args.operation == 'select':
        print(manifest or '')
        return
    if manifest is None:
        print('No modular runtime declared for this host')
        return
    config = config_load(manifest)
    if args.source:
        config['source'] = str(Path(args.source).resolve())
    for key in ('tier0', 'flags', 'highway', 'grammars', 'ucd'):
        if not Path(config[key]).exists():
            raise ValueError('Required modular input is absent: ' + key + '=' + config[key])
    if args.operation == 'check':
        print('Modular host and prepared inputs match the declaration')
        return
    installing = args.operation == 'install'
    if installing != (os.geteuid() == 0):
        raise ValueError('Install uses sudo ./setup.sh; recurring deployment runs without sudo')
    with host_lock(config):
        if installing:
            prepare(config)
            provision_token(config)
        else:
            live = config_load(config['installed_config'])
            if any(config[k] != live[k] for k in config if k not in ('source', 'operator_client')):
                raise ValueError('Installation configuration changed; run setup before deployment')
            if not all(path.is_file() for path in (UNITS / UNIT, Path(config['environment_file']),
                    UNITS / 'laplace-modular-mcp-restart.path')):
                raise ValueError('Modular installation is incomplete; run sudo ./setup.sh before deployment')
            ensure_listener_credential(config)
            sql(config, grants(config))
        receipt_path = Path(config['receipts']) / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
        receipt_path.mkdir(parents=True)
        if installing:
            operator = pwd.getpwnam(config['operator'])
            os.chown(receipt_path, operator.pw_uid, grp.getgrnam(config['deployment_group']).gr_gid)
        receipt_path.chmod(0o2775)
        try:
            release = package(config, receipt_path, repair=installing)
            activate(config, release, receipt_path, installing)
            if installing:
                restart_units(config)
                install_credential_helper(config)
                client = config.get('operator_client')
                if client:
                    checked(['runuser', '-u', config['operator'], '--', 'python3',
                             ROOT / 'installation/install-client.py', '--installation', config['installed_config'],
                             *[value for key in ('role', 'work', 'data', 'command', 'configuration')
                               for value in ('--' + key, client[key])],
                             *[value for key in ('source', 'models') if key in client
                               for value in ('--' + key, client[key])]])
            atomic(receipt_path / 'acceptance.json', json.dumps({'scope': 'modular MCP installed runtime', 'host': config['host'],
                'release': str(release), 'unit': UNIT, 'runtime_user': config['runtime_user'], 'database_role': config['role'],
                'result': 'passed', 'runtime_evidence': str(receipt_path / 'runtime.json')}, indent=2) + '\n')
            print('Modular runtime verified: ' + str(receipt_path / 'acceptance.json'))
        finally:
            spec = importlib.util.spec_from_file_location('storage', ROOT / 'installation/storage.py')
            storage = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(storage)
            storage.cleanup_native(config, receipt_path / 'cleanup.json')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('Modular operation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
