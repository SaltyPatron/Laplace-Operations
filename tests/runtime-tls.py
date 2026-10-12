"""Real PostgreSQL/.NET regression for a colliding host certificate in the OS trust store.

Run unprivileged with --pgbin /path/bin --probe /path/runtime-db-probe.dll.
The probe must use the deployed Npgsql assembly; no serving configuration is changed.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pgbin', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise ValueError('Run this disposable cluster test unprivileged')
    tls = load('tls', ROOT / 'installation/runtime_tls.py')
    sync = load('sync', ROOT / 'secrets/database-sync.py')
    atomic = sync.atomic
    sync.atomic = lambda path, text, mode, uid, gid: atomic(path, text, mode, os.geteuid(), os.getegid())
    policy = json.loads((ROOT / 'installation/hart-server-runtime.json').read_text())['tls']
    with tempfile.TemporaryDirectory(prefix='laplace-tls-') as temporary:
        root = Path(temporary)
        data = root / 'data'
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        def run(argv, **kwargs):
            result = subprocess.run(argv, capture_output=True, text=True, timeout=45, **kwargs)
            if result.returncode:
                raise RuntimeError('Fixture command failed: ' + str(argv[0]) + ': ' + result.stderr)
            return result.stdout.strip()
        run([str(args.pgbin / 'initdb'), '-D', str(data), '-U', 'fixture_owner', '-A', 'trust', '--no-locale'])
        # Existing distro snakeoil cert has CN=hart-server, independently from PostgreSQL's cert.
        key, certificate = data / 'server.key', data / 'server.crt'
        run(['openssl', 'req', '-new', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
             '-keyout', str(key), '-out', str(certificate), '-subj', '/CN=hart-server'])
        key.chmod(0o600)
        key_hash = hashlib.sha256(key.read_bytes()).hexdigest()
        ctl = [str(args.pgbin / 'pg_ctl'), '-D', str(data)]
        run(ctl + ['-l', str(root / 'postgres.log'), '-o',
                   f'-F -k {root} -h 127.0.0.1 -p {port} -c ssl=on', '-w', 'start'])
        try:
            def sql(statement):
                return run([str(args.pgbin / 'psql'), '-XwAt', '-v', 'ON_ERROR_STOP=1', '-h', str(root),
                            '-p', str(port), '-U', 'fixture_owner', '-d', 'postgres', '-f', '-'], input=statement)
            password = secrets.token_hex(32)
            sql("CREATE ROLE fixture_runtime LOGIN PASSWORD '" + password + "';")
            (data / 'pg_hba.conf').write_text('local all all trust\nhostssl postgres fixture_runtime 127.0.0.1/32 scram-sha-256\n')
            sql('SELECT pg_reload_conf()')
            def probe(ca, mode='VerifyFull'):
                connection = f'Host=127.0.0.1;Port={port};Username=fixture_runtime;Database=postgres;SSL Mode={mode};Root Certificate={ca};Timeout=5'
                result = subprocess.run(['dotnet', str(args.probe)], input=json.dumps({'connection': connection, 'password': password}),
                                        text=True, capture_output=True, timeout=20)
                return result.returncode, json.loads(result.stdout)
            before_code, before = probe(certificate, 'Require')
            assert before_code and before['openssl_identifier_mismatch'], before
            policy['root_certificate'] = str(root / 'runtime-ca.crt')
            config = {'tls': policy, 'database_data': str(data), 'database_host': '127.0.0.1', 'port': port, 'work': str(root)}
            with tls.configured(config, sql, sync):
                code, result = probe(policy['root_certificate'])
                assert code == 0 and result['tls'] and result['role'] == 'fixture_runtime', result
            established = certificate.read_bytes()
            with tls.configured(config, sql, sync):
                assert certificate.read_bytes() == established
            assert hashlib.sha256(key.read_bytes()).hexdigest() == key_hash
            wrong, _ = probe('/etc/ssl/certs/ssl-cert-snakeoil.pem')
            assert wrong, 'Npgsql accepted the wrong CA'
            changed = copy.deepcopy(config)
            changed['tls']['subject'] += ' renewal-test'
            try:
                with tls.configured(changed, sql, sync):
                    raise RuntimeError('injected failure')
            except RuntimeError as error:
                assert str(error) == 'injected failure'
            assert certificate.read_bytes() == established
            for _ in range(30):
                try:
                    tls.verify_endpoint('127.0.0.1', port, Path(policy['root_certificate']))
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise AssertionError('Certificate rollback did not restore a working TLS endpoint')
            print(json.dumps({'passed': True, 'reproduced_openssl_error_30': True,
                'npgsql_verify_full': 'passed', 'wrong_ca': 'denied', 'private_key': 'preserved',
                'repeat_install': 'unchanged', 'failed_rotation': 'rolled back',
                'npgsql_sha256': hashlib.sha256(args.probe.with_name('Npgsql.dll').read_bytes()).hexdigest()}))
        finally:
            run(ctl + ['-m', 'immediate', '-w', 'stop'])


if __name__ == '__main__':
    main()
