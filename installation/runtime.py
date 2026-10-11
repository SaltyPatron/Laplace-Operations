#!/usr/bin/env python3
"""Install the declared API/MCP identities; preserve data and roll back failed activation."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
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
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


SYNC = module('runtime_sync', ROOT / 'secrets/knowledge-sync.py')


def checked(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed (exit {result.returncode})')
    return result.stdout.strip()


def declarations(path):
    return module('runtime_machine', ROOT / 'machine-env.py').resolve(path, {}, explicit=True)


def validate(config):
    for key in ('host', 'operator', 'record', 'database', 'role', 'database_owner', 'runtime_user', 'pg_os_user', 'bao_role'):
        if not re.fullmatch(r'[a-z][a-z0-9_-]*', config[key]):
            raise ValueError('Invalid installation identity: ' + key)
    if not re.fullmatch(r'[a-z][a-z0-9_-]*', config['mcp']['user']):
        raise ValueError('Invalid MCP OS identity')
    identities = [config['role'], config['knowledge']['role'], config['mcp']['role'], config['database_owner']]
    if len(set(identities)) != len(identities):
        raise ValueError('Application, knowledge, MCP and migration roles must be distinct')
    if config['runtime_user'] in ('root', config['pg_os_user'], config['operator'], config['mcp']['user']):
        raise ValueError('API identity must be independent of administration and MCP')
    if config['mcp']['user'] in ('root', config['pg_os_user'], config['operator']):
        raise ValueError('MCP identity must be independent of administration')
    for item in (config, config['knowledge'], config['mcp']):
        if not re.fullmatch(r'[a-z][a-z0-9_-]*', item['role']):
            raise ValueError('Invalid runtime database role')
        if not 1 <= int(item['pool_max']) <= int(item['connection_limit']):
            raise ValueError('Runtime pool exceeds its role connection allowance')
    for key in ('pgbin', 'pgsocket', 'database_data', 'prefix', 'machine_file', 'host_lock', 'credentials', 'work'):
        path = Path(config[key])
        if not path.is_absolute() or path == Path('/') or '..' in path.parts or path.is_symlink():
            raise ValueError('Invalid installation path: ' + key)
    prefix = Path(config['prefix'])
    states = [Path(config['state']), Path(config['mcp']['state'])]
    for state in states:
        if not state.is_absolute() or state == Path('/') or '..' in state.parts or state.is_symlink():
            raise ValueError('Invalid runtime state directory')
        if state == prefix or state in prefix.parents or prefix in state.parents:
            raise ValueError('Runtime state and deployed binaries must be independent')
    if states[0] == states[1] or states[0] in states[1].parents or states[1] in states[0].parents:
        raise ValueError('API and MCP state must be independent')
    if not config['bao_address'].startswith('https://'):
        raise ValueError('OpenBao requires HTTPS')
    for base in (config['public_base'], config['mcp']['base']):
        if not base.startswith(('http://127.0.0.1:', 'https://')):
            raise ValueError('Verification requires local HTTP or HTTPS')
    if not 1 <= int(config['port']) <= 65535:
        raise ValueError('Invalid database port')
    # This installation pins existing application data. It is not a database migration.
    if config['knowledge']['database'] != config['database']:
        raise ValueError('This setup requires the current co-located application and knowledge database')
    for item in (config, config['knowledge']):
        if item['database_host'] != '127.0.0.1' or int(item['port']) != int(config['port']):
            raise ValueError('Runtime installation requires the declared local cluster')


def preflight(config):
    validate(config)
    if socket.gethostname().split('.')[0].lower() != config['host']:
        raise ValueError('The runtime declaration belongs to another host')
    current = declarations(Path(config['machine_file']))
    for key, expected in {'LAPLACE_INSTALL_PREFIX': config['prefix'], 'LAPLACE_PGDATA': config['database_data'],
                          'LAPLACE_PG_DIR': str(Path(config['pgbin']).parent),
                          'LAPLACE_ROLE': config['database_owner']}.items():
        if current.get(key) != expected:
            raise ValueError('Installed configuration differs from runtime declaration: ' + key)
    prefix = Path(config['prefix'])
    for path in (prefix / 'app/laplace-api.env', prefix / 'app/laplace-mcp.env',
                 prefix / 'app/operations/scripts/verify-application-release.py',
                 prefix / 'app/.laplace-source-revision', Path(config['pgbin']) / 'psql'):
        if not path.is_file():
            raise ValueError('Missing installed prerequisite: ' + str(path))
    for service in ('laplace-api', 'laplace-mcp', config['database_service']):
        checked(['systemctl', 'is-active', '--quiet', service], timeout=10)
    for path in config['required_mounts']:
        checked(['mountpoint', '-q', path], timeout=10)
    for name, state in ((config['runtime_user'], config['state']), (config['mcp']['user'], config['mcp']['state'])):
        try:
            account = pwd.getpwnam(name)
        except KeyError:
            continue
        if account.pw_uid == 0 or account.pw_dir != state:
            raise ValueError('Existing runtime account has a different home: ' + name)
    return {'host': config['host'], 'release': (prefix / 'app/.laplace-source-revision').read_text().strip(),
            'application_database': config['database'], 'application_data_moved': False}


class Bao:
    def __init__(self, config):
        self.env = {k: v for k, v in os.environ.items() if k not in ('BAO_TOKEN', 'VAULT_TOKEN', 'BAO_NAMESPACE', 'VAULT_NAMESPACE')}
        self.env['BAO_ADDR'] = config['bao_address']
        self.command = ['bao']
        if os.geteuid() == 0:
            self.command = ['runuser', '-u', config['operator'], '--', 'bao']
        elif pwd.getpwuid(os.geteuid()).pw_name != config['operator']:
            raise ValueError('Use the declared installation operator')

    def call(self, args, payload=None, missing=False):
        result = subprocess.run(self.command + args, env=self.env, input=payload,
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            if missing and 'No value found at ' in result.stderr:
                return None
            raise ValueError('OpenBao operation failed; check the declared operator login and policy')
        return result.stdout

    def record(self, path, selectors):
        prior = self.call(['kv', 'get', '-format=json', '-mount=kv', path], missing=True)
        if prior is not None:
            record = json.loads(prior)['data']['data']
            if any(str(record.get(k)) != str(v) for k, v in selectors.items()):
                raise ValueError('Existing OpenBao record selects a different installation: ' + path)
            if not re.fullmatch(r'[0-9a-f]{64}', record.get('password', '')):
                raise ValueError('Existing runtime password is not a generated credential')
            return record
        record = dict(selectors, password=secrets.token_hex(32))
        self.call(['kv', 'put', '-mount=kv', path, '-'], json.dumps(record))
        return record

    def enroll(self, config):
        name = config['bao_role']
        paths = [f'kv/data/hosts/{config["host"]}/{record}' for record in ('knowledge', config['record'])]
        policy = ''.join(f'path "{path}" {{ capabilities = ["read"] }}\n' for path in paths)
        policy += ('path "sys/capabilities-self" { capabilities = ["update"] }\n'
                   'path "auth/token/lookup-self" { capabilities = ["read"] }\n'
                   'path "auth/token/revoke-self" { capabilities = ["update"] }\n')
        self.call(['policy', 'write', name, '-'], policy)
        self.call(['write', '-format=json', 'auth/approle/role/' + name, '-'], json.dumps({
            'token_policies': [name], 'token_no_default_policy': True, 'token_ttl': '5m',
            'token_max_ttl': '10m', 'secret_id_ttl': 0, 'secret_id_num_uses': 0, 'bind_secret_id': True}))
        role_id = json.loads(self.call(['read', '-format=json', f'auth/approle/role/{name}/role-id']))['data']['role_id']
        credential = Path(config['credentials'])
        if credential.exists():
            if credential.is_symlink() or credential.stat().st_uid != 0 or credential.stat().st_mode & 0o077:
                raise ValueError('Existing workload enrollment must be root-owned and private')
            if json.loads(credential.read_text())['role_id'] != role_id:
                raise ValueError('Existing workload enrollment belongs to another role')
            return
        secret_id = json.loads(self.call(['write', '-format=json', '-f', f'auth/approle/role/{name}/secret-id']))['data']['secret_id']
        SYNC.atomic(credential, json.dumps({'role_id': role_id, 'secret_id': secret_id}) + '\n', 0o600, 0, 0)


def connection(item, peer=False, socket_path=None):
    return (f'Host={socket_path if peer else item["database_host"]};Port={int(item["port"])};'
            f'Database={item["database"]};Username={item["role"]};'
            + ('' if peer else 'SSL Mode=Require;') + f'Maximum Pool Size={int(item["pool_max"])}')


def mcp_verify(config):
    prefix = Path(config['prefix'])
    token = declarations(prefix / 'secrets/mcp.env')['LAPLACE_MCP_TOKEN']
    payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
        'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'runtime-setup', 'version': '1'}}}).encode()
    session = None
    for authenticated, expected in ((False, 401), (True, 200)):
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        try:
            with urllib.request.urlopen(urllib.request.Request(config['mcp']['base'].rstrip('/') + '/mcp', data=payload, headers=headers), timeout=15) as response:
                status, body = response.status, response.read(1048576).decode()
                session = response.headers.get('Mcp-Session-Id')
        except urllib.error.HTTPError as error:
            status, body = error.code, ''
        if status != expected or (authenticated and ('protocolVersion' not in body or 'serverInfo' not in body)):
            raise ValueError('Installed MCP authentication/initialization failed')
    headers['MCP-Protocol-Version'] = '2025-06-18'
    if session:
        headers['Mcp-Session-Id'] = session
    for message in ({'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                     'params': {'name': 'api', 'arguments': {'query': 'substrate_counts'}}}):
        with urllib.request.urlopen(urllib.request.Request(config['mcp']['base'].rstrip('/') + '/mcp',
                data=json.dumps(message).encode(), headers=headers), timeout=30) as response:
            body = response.read(1048576).decode()
        if 'id' in message:
            if body.lstrip().startswith('{'):
                reply = json.loads(body)
            else:
                reply = next((json.loads(line[5:].strip()) for line in body.splitlines()
                              if line.startswith('data:') and line[5:].strip().startswith('{')), {})
            if reply.get('error') or reply.get('result', {}).get('isError') is not False:
                raise ValueError('MCP substrate_counts tool failed')
    return {'anonymous': 'denied', 'authenticated_initialize': 'passed', 'substrate_counts_tool': 'passed'}


def install(config, lock):
    env = dict(os.environ, LAPLACE_HOST_LOCK_FD=str(lock.fileno()),
               PATH=config['pgbin'] + os.pathsep + os.environ.get('PATH', ''), BAO_ADDR=config['bao_address'])

    def helper(name, args=(), payload=None):
        try:
            output = checked(['python3', str(ROOT / 'secrets' / name), *args], env=env,
                pass_fds=(lock.fileno(),), input=json.dumps(payload) if payload is not None else None, timeout=180)
        except RuntimeError:
            phase = args[1] if args and args[0] == '--phase' else 'provision/verify'
            raise RuntimeError(f'{name}: {phase} failed; no acceptance receipt issued') from None
        return json.loads(output)

    def sql(statement):
        return checked(['runuser', '-u', config['pg_os_user'], '--', config['pgbin'] + '/psql',
            '-XwAt', '-v', 'ON_ERROR_STOP=1', '-h', config['pgsocket'], '-p', str(config['port']),
            '-d', config['database'], '-f', '-'], input=statement, timeout=30)

    if Path(sql('SHOW data_directory')).resolve() != Path(config['database_data']).resolve():
        raise ValueError('Connected cluster differs from runtime declaration')
    bao = Bao(config)
    bao.call(['token', 'lookup', '-field=ttl'])
    print('Preparing scoped runtime credentials and database roles...', flush=True)
    for record_name, item in ((config['record'], config), ('knowledge', config['knowledge'])):
        record = bao.record(f'hosts/{config["host"]}/{record_name}',
                            {key: item[key] for key in ('database_host', 'database', 'role', 'port')})
        item['password'] = record['password']
    bao.enroll(config)
    helper('application-runtime.py', ['--phase', 'prepare'], config)
    knowledge_config = dict(config['knowledge'], psql=config['pgbin'] + '/psql', admin_socket=config['pgsocket'],
        admin_role=config['pg_os_user'], admin_os_user=config['pg_os_user'], schema_owner=config['database_owner'],
        lock=config['host_lock'], client_address='127.0.0.1')
    helper('knowledge-role.py', payload=knowledge_config)
    mcp, state, prefix = config['mcp'], Path(config['mcp']['state']), Path(config['prefix'])
    try:
        account = pwd.getpwnam(mcp['user'])
    except KeyError:
        checked(['useradd', '--system', '--user-group', '--home-dir', str(state), '--no-create-home',
                 '--shell', '/usr/sbin/nologin', mcp['user']], timeout=20)
        account = pwd.getpwnam(mcp['user'])
    for directory in (state, state / 'logs', state / 'tmp', state / 'out'):
        if any(path.is_symlink() for path in (directory, *directory.parents)):
            raise ValueError('Runtime state must not traverse symbolic links')
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
        os.chown(directory, account.pw_uid, account.pw_gid)
    helper('knowledge-role.py', payload=dict(knowledge_config, role=mcp['role'], peer_user=mcp['user'],
                                            connection_limit=mcp['connection_limit']))
    fresh = helper('knowledge-sync.py', ['--host', config['host'], '--credentials', config['credentials'],
        '--user', config['runtime_user'], '--prefix', config['prefix'], '--machine-file', config['machine_file'],
        '--lock', config['host_lock'], '--bao-address', config['bao_address'], '--application-record', config['record']])
    SYNC.validate_knowledge_receipt(prefix, fresh['native_receipt'])
    machine, api, mcp_env = Path(config['machine_file']), prefix / 'app/laplace-api.env', prefix / 'app/laplace-mcp.env'
    dropins = [Path(f'/etc/systemd/system/laplace-{service}.service.d/runtime-identity.conf') for service in ('api', 'mcp')]
    for path in dropins:
        path.parent.mkdir(parents=True, exist_ok=True)
    prior_user = checked(['systemctl', 'show', 'laplace-api', '-p', 'User', '--value'], timeout=10)

    def recover():
        checked(['systemctl', 'daemon-reload'], timeout=20)
        checked(['systemctl', 'restart', 'laplace-mcp'], timeout=30)
        SYNC.activate(prior_user, prefix, config['public_base'])

    print('Activating API and MCP identities; failed verification restores serving configuration...', flush=True)
    with SYNC.configuration_transaction([machine, api, mcp_env, *dropins], recover):
        mcp_connection = connection(dict(mcp, database=config['knowledge']['database'], port=config['port']), True, config['pgsocket'])
        knowledge_connection = connection(config['knowledge'])
        SYNC.assignments(machine, {'LAPLACE_KNOWLEDGE_RUNTIME_DB': knowledge_connection,
            'LAPLACE_MCP_RUNTIME_DB': mcp_connection, 'LAPLACE_MCP_USER': mcp['user'],
            'LAPLACE_MCP_STATE_DIR': state, 'LAPLACE_MCP_LOG_DIR': state / 'logs',
            'LAPLACE_APP_DBNAME': config['database'], 'LAPLACE_APP_PGHOST': config['pgsocket'],
            'LAPLACE_APP_PGPORT': config['port'], 'LAPLACE_APP_ROLE': config['database_owner'],
            'LAPLACE_BAO_KNOWLEDGE_HOST': config['host'], 'LAPLACE_API_VERIFICATION_URL': config['public_base']})
        SYNC.assignments(api, {'LAPLACE_DB': knowledge_connection})
        SYNC.assignments(mcp_env, {'LAPLACE_DB': mcp_connection, 'LAPLACE_OPS_LOG_DIR': state / 'logs',
            'LAPLACE_OUT': state / 'out', 'LAPLACE_AGENTS_CONFIG': state / 'agents.json'})
        SYNC.atomic(dropins[1], f'[Service]\nUser={mcp["user"]}\nGroup={mcp["user"]}\nUMask=0077\n'
            f'EnvironmentFile=-{prefix}/secrets/agents.env\n'
            f'Environment="HOME={state}" "TMPDIR={state}/tmp" "TMP={state}/tmp" "TEMP={state}/tmp"\n', 0o644, 0, 0)
        checked(['systemctl', 'daemon-reload'], timeout=20)
        checked(['systemctl', 'restart', 'laplace-mcp'], timeout=30)
        helper('application-runtime.py', ['--phase', 'activate'], config)
        verification = helper('application-runtime.py', ['--phase', 'verify'], config)
        verification['mcp'] = mcp_verify(config)
        knowledge_args = ['runuser', '-u', config['runtime_user'], '--', config['pgbin'] + '/psql',
            '-XwAt', '-v', 'ON_ERROR_STOP=1', '-h', config['knowledge']['database_host'],
            '-p', str(config['port']), '-U', config['knowledge']['role'], '-d', config['knowledge']['database'], '-f', '-']
        knowledge_env = dict(os.environ, PGPASSFILE=str(Path(config['state']) / '.pgpass'),
                             PGSSLMODE='require', PGCONNECT_TIMEOUT='10')
        knowledge_env.pop('PGPASSWORD', None)
        actual = checked(knowledge_args, env=knowledge_env,
            input="SELECT current_user; SELECT encode(laplace.perfcache_receipt(),'hex');", timeout=20)
        if actual.splitlines() != [config['knowledge']['role'], fresh['native_receipt']]:
            raise ValueError('API knowledge identity/native operation differs from the selected substrate')
        refused = subprocess.run(knowledge_args, env=knowledge_env, input='SELECT * FROM app.tenants LIMIT 1;',
                                 text=True, capture_output=True, timeout=20)
        if not refused.returncode or 'permission denied' not in refused.stderr:
            raise ValueError('API knowledge login can cross the application data boundary')
        verification['knowledge'] = {'role': config['knowledge']['role'], 'native_receipt': fresh['native_receipt'],
                                     'application_data': 'denied'}
        peer_args = ['runuser', '-u', mcp['user'], '--', config['pgbin'] + '/psql', '-XwAt', '-v', 'ON_ERROR_STOP=1',
            '-h', config['pgsocket'], '-p', str(config['port']), '-U', mcp['role'], '-d', config['knowledge']['database'], '-f', '-']
        peer_result = checked(peer_args, input="SELECT current_user; SELECT encode(laplace.perfcache_receipt(),'hex');", timeout=20)
        if peer_result.splitlines() != [mcp['role'], fresh['native_receipt']]:
            raise ValueError('MCP peer identity/native operation differs from the selected substrate')
        denied = subprocess.run(peer_args, input='SELECT * FROM app.tenants LIMIT 1;', text=True, capture_output=True, timeout=20)
        if not denied.returncode or 'permission denied' not in denied.stderr:
            raise ValueError('MCP can cross the application data boundary')
        runner = pwd.getpwnam(declarations(machine)['LAPLACE_AGENT_USER'])
        for path, access in ((Path(runner.pw_dir) / '.pgpass', '-r'), (Path(config['credentials']), '-r'),
                             (prefix / 'app/mcp-runtime/Laplace.Endpoints.Mcp.dll', '-w')):
            if not path.exists() or subprocess.run(['runuser', '-u', mcp['user'], '--', 'test', access, str(path)]).returncode != 1:
                raise ValueError('MCP deployment/runtime access boundary failed')
        verification['mcp'].update(database_peer_identity=mcp['role'], native_receipt=fresh['native_receipt'], application_data='denied')
    # This existing setup operation installs a root-owned credential refresh timer.
    # A timer failure leaves verified serving identities in place and is retryable.
    checked(['bash', str(ROOT / 'setup.sh'), 'knowledge-client'], env=dict(env, LAPLACE_MACHINE_ENV=config['machine_file']),
            pass_fds=(lock.fileno(),), timeout=180)
    checked(['systemctl', 'is-active', '--quiet', 'laplace-knowledge-refresh.timer'], timeout=10)
    verification['credential_refresh_timer'] = 'active'
    return verification


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).with_name('hart-server-runtime.json'))
    parser.add_argument('--check', action='store_true', help='Check existing installation and operator authentication without changes')
    args = parser.parse_args()
    config = json.loads(args.manifest.read_text())
    receipt = preflight(config)
    Bao(config).call(['token', 'lookup', '-field=ttl'])
    if args.check:
        print(json.dumps(dict(receipt, preflight='passed', activated=False)))
        return
    if os.geteuid() != 0:
        raise ValueError('Install identities with sudo ./setup.sh runtime; --check does not require sudo')
    with open(config['host_lock'], 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        work = Path(config['work'])
        work.mkdir(parents=True, exist_ok=True)
        started = datetime.now(timezone.utc)
        output = work / (started.strftime('%Y%m%dT%H%M%SZ') + '-runtime-' + uuid.uuid4().hex[:8] + '.json')
        receipt.update(operation='runtime', started_utc=started.isoformat(),
                       manifest_sha256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                       source=checked(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], timeout=10))
        try:
            receipt['verification'] = install(config, lock)
            # The newly enabled timer may fire immediately. Release the installation
            # lock before waiting for its independent credential-refresh operation.
            fcntl.flock(lock, fcntl.LOCK_UN)
            checked(['systemctl', 'start', 'laplace-knowledge-refresh.service'], timeout=90)
            receipt['status'] = 'passed'
        except Exception as error:
            receipt.update(status='failed', error=str(error))
            raise
        finally:
            receipt['finished_utc'] = datetime.now(timezone.utc).isoformat()
            SYNC.atomic(output, json.dumps(receipt, indent=2) + '\n', 0o644, 0, 0)
            print('Runtime setup receipt: ' + str(output), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Runtime setup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
