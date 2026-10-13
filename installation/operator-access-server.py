"""Enroll a declared Windows operator certificate in an existing PostgreSQL cluster."""
import datetime
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def literal(value):
    return "E'" + value.replace('\\', '\\\\').replace("'", "''") + "'"


def enroll(config):
    target = config['target']
    if target.get('superuser') is not True:
        raise ValueError('This enrollment requires an explicitly declared administrator target')
    role = config['role']
    subject = config['certificate_subject']
    if not re.fullmatch(r'[a-z][a-z0-9_]{0,62}', role):
        raise ValueError('Invalid operator database role')
    if not re.fullmatch(r'laplace-operator-S-1-[0-9-]+', subject):
        raise ValueError('Invalid Windows operator subject')
    for address in target['client_addresses']:
        network = ipaddress.ip_network(address)
        if network.prefixlen != network.max_prefixlen:
            raise ValueError('Operator access requires individual client addresses')
    certificate = config['certificate']
    inspected = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'],
                               input=certificate, text=True, capture_output=True, check=True).stdout.strip()
    if inspected != 'subject=CN=' + subject:
        raise ValueError('Certificate subject differs from the declared Windows identity')
    environment = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    def sql(statement):
        result = subprocess.run(target['psql'] + ['-X', '-w', '-d', 'postgres', '-At',
                                '-v', 'ON_ERROR_STOP=1', '-c', statement], env=environment,
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()
    def read(path, optional=False):
        return json.loads(sql('SELECT to_json(COALESCE(pg_read_file(' + literal(str(path)) +
                              ',0,1048576,' + ('true' if optional else 'false') + "),''))"))
    def write(path, content):
        if any(character in content for character in ('\x00', '\x01', '\x02', '\r')):
            raise ValueError('Configuration contains unsupported control characters')
        # Single-column CSV preserves configuration backslashes; NULL renders a blank line.
        sql("COPY (SELECT NULLIF(line,'') FROM unnest(string_to_array(" + literal(content.rstrip('\n')) +
            ", E'\\n')) AS line) TO " + literal(str(path)) +
            " WITH (FORMAT csv, DELIMITER E'\\x01', QUOTE E'\\x02')")
    if sql('SHOW data_directory') != target['data']:
        raise ValueError('Wrong PostgreSQL cluster')
    if sql("SELECT rolsuper FROM pg_roles WHERE rolname=current_user") != 't':
        raise ValueError('Existing database administrator access is required')
    lock = open('/run/lock/laplace/host-resource.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    hba = Path(sql('SHOW hba_file'))
    ident = Path(sql('SHOW ident_file'))
    ca = Path(target['data']) / 'laplace_operator_ca.crt'
    operator_hba = hba.with_name('pg_hba.operator.conf')
    operator_ident = ident.with_name('pg_ident.operator.conf')
    old_ca = sql('SHOW ssl_ca_file')
    if old_ca and old_ca != str(ca):
        raise ValueError('Preserve the existing client CA; explicit trust-store merge is required')
    originals = {hba: read(hba), ident: read(ident), operator_hba: read(operator_hba, True),
                 operator_ident: read(operator_ident, True), ca: read(ca, True)}
    existing_role = sql('SELECT rolcanlogin::int||\',\'||rolsuper::int||\',\'||(rolpassword IS NULL)::int '
                        'FROM pg_authid WHERE rolname=' + literal(role))
    if existing_role and existing_role != '1,1,1':
        raise ValueError('Existing operator role does not match password-free administration')
    rules = ['# Human operator: Windows user-store certificate; no database password.']
    rules += [f'hostssl all {role} {address} cert map=laplace_operator' for address in target['client_addresses']]
    rules += [f'host all {role} 0.0.0.0/0 reject', f'host all {role} ::/0 reject']
    desired = {operator_hba: '\n'.join(rules)+'\n',
               operator_ident: f'laplace_operator {subject} {role}\n', ca: certificate}
    for path, include in ((hba, 'include_if_exists pg_hba.operator.conf'),
                          (ident, 'include_if_exists pg_ident.operator.conf')):
        desired[path] = originals[path] if include in originals[path].splitlines() else include+'\n'+originals[path]
    if existing_role and old_ca == str(ca) and all(originals[p].rstrip('\n') == v.rstrip('\n') for p,v in desired.items()):
        lock.close()
        return {'host':target['ssh'],'role':role,'authentication':'cert','changed':False}
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backups = {}
    for path, content in originals.items():
        if content:
            backup = Path(target['data']) / (path.name + '.operator-before-' + stamp)
            write(backup, content)
            backups[str(path)] = str(backup)
    created = False
    try:
        if not existing_role:
            sql('CREATE ROLE "' + role + '" LOGIN SUPERUSER PASSWORD NULL')
            created = True
        for path, content in desired.items():
            if originals[path].rstrip('\n') != content.rstrip('\n'):
                write(path, content)
        if sql('SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL') != '0':
            raise RuntimeError('Operator HBA did not parse')
        if sql('SELECT count(*) FROM pg_ident_file_mappings WHERE error IS NOT NULL') != '0':
            raise RuntimeError('Operator identity map did not parse')
        sql('ALTER SYSTEM SET ssl_ca_file=' + literal(str(ca)))
        if sql('SELECT pg_reload_conf()') != 't':
            raise RuntimeError('Configuration reload failed')
        for _ in range(30):
            if sql('SHOW ssl_ca_file') == str(ca):
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Client certificate trust did not activate')
        if sql('SELECT count(*) FROM pg_file_settings WHERE error IS NOT NULL') != '0':
            raise RuntimeError('PostgreSQL reports invalid configuration')
    except BaseException:
        for path, content in originals.items():
            write(path, content)
        sql('ALTER SYSTEM SET ssl_ca_file=' + literal(old_ca))
        sql('SELECT pg_reload_conf()')
        if created:
            sql('DROP ROLE "' + role + '"')
        raise
    finally:
        lock.close()
    return {'host': target['ssh'], 'role': role, 'windows_subject': subject,
            'password_present': False, 'authentication': 'cert', 'backups': backups,
            'previous_ssl_ca_file': old_ca, 'role_created': created}


if __name__ == '__main__':
    print(json.dumps(enroll(json.load(sys.stdin)), indent=2))
