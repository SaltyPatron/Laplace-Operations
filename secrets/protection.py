#!/usr/bin/env python3
"""Install abuse controls and bounded rotation; preserve an oversized closed audit log."""
import argparse
import concurrent.futures
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import uuid


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs)


def atomic(path, value, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), mode)
            output.write(value)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def configurations(c, site):
    # Keys use the socket peer, never a caller-controlled forwarding header.
    http = f'''map $uri $laplace_bao_renewal {{
    default "";
    /v1/auth/token/renew-self $binary_remote_addr;
}}
limit_req_zone $binary_remote_addr zone=laplace_bao_client:1m rate={c['client_rate']}r/s;
limit_req_zone $laplace_bao_renewal zone=laplace_bao_renewal:1m rate={c['renewal_rate']}r/s;
limit_req_zone $server_name zone=laplace_bao_total:1m rate={c['total_rate']}r/s;
'''
    server = f'''limit_req zone=laplace_bao_client burst={c['client_burst']} nodelay;
limit_req zone=laplace_bao_renewal burst={c['renewal_burst']} nodelay;
limit_req zone=laplace_bao_total burst={c['total_burst']} nodelay;
limit_req_status 429;
limit_req_log_level warn;
error_page 429 = @laplace_bao_retry;
location @laplace_bao_retry {{
    add_header Retry-After 1 always;
    return 429;
}}
'''
    marker = '    include ' + c['server_configuration'] + ';'
    selector = 'server_name ' + c['hostname'] + ';'
    if site.count(selector) != 1:
        raise RuntimeError('Expected exactly one declared OpenBao nginx server; no configuration changed')
    site = site.replace(marker + '\n', '')
    site = site.replace(selector, selector + '\n' + marker)
    generation = hashlib.sha256((http + server).encode()).hexdigest()[:16]
    server += f'add_header X-Laplace-Secrets-Protection {generation} always;\n'
    return http, server, site


def await_reload(c, server):
    generation = re.search(r'X-Laplace-Secrets-Protection (\w+)', server).group(1)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        response = run(['curl', '--silent', '--show-error', '--max-time', '5', '--noproxy', '*',
                        '--resolve', f"{c['hostname']}:443:{c['address']}",
                        '--dump-header', '-', '--output', '/dev/null',
                        'https://' + c['hostname'] + '/v1/sys/health'])
        if re.search(r'^X-Laplace-Secrets-Protection: ' + generation + r'\s*$', response.stdout, re.I | re.M):
            return
        time.sleep(0.25)
    raise RuntimeError('Nginx did not serve the installed protection generation within 30 seconds')


def status(c, uri, method='GET'):
    result = run(['curl', '--silent', '--show-error', '--max-time', '10', '--noproxy', '*',
                  '--resolve', f"{c['hostname']}:443:{c['address']}", '-X', method,
                  '--output', '/dev/null', '--write-out', '%{http_code}',
                  'https://' + c['hostname'] + uri])
    return int(result.stdout)


def open_file(c, path):
    process = int(run(['systemctl', 'show', c['service'], '-p', 'MainPID', '--value']).stdout)
    if process <= 0:
        raise RuntimeError('OpenBao is not running')
    target = path.stat()
    for fd in Path(f'/proc/{process}/fd').iterdir():
        try:
            held = fd.stat()
            if (held.st_dev, held.st_ino) == (target.st_dev, target.st_ino):
                return True
        except FileNotFoundError:
            pass
    return False


def close_oversized_audit(c):
    audit = Path(c['audit_log'])
    closed = sorted(audit.parent.glob(audit.name + '.recovery-*'))
    if audit.stat().st_size > c['overflow_threshold_mib'] * 1024**2:
        if not open_file(c, audit):
            raise RuntimeError('Declared audit file is not held by OpenBao; refusing to rotate an unverified path')
        previous = audit.stat()
        target = audit.with_name(audit.name + '.recovery-' + uuid.uuid4().hex)
        audit.rename(target)
        fd = os.open(audit, os.O_CREAT | os.O_EXCL | os.O_WRONLY, previous.st_mode & 0o777)
        os.fchown(fd, previous.st_uid, previous.st_gid)
        os.close(fd)
        closed.append(target)
    if closed:
        # SIGHUP reopens the file audit device without restarting/unsealing Bao.
        run(['systemctl', 'kill', '--kill-who=main', '--signal=HUP', c['service']])
        for _ in range(50):
            if all(not open_file(c, path) for path in closed) and open_file(c, audit):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('OpenBao has not released the closed audit log; all bytes are preserved')
    return closed


def archive(c, path):
    if path.is_symlink() or not path.is_file() or open_file(c, path):
        raise RuntimeError('Audit archive input must be a closed regular file')
    directory = Path(c['overflow_archive_directory'])
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    before = path.stat()
    required = int(before.st_size * 1.01) + c['archive_reserve_mib'] * 1024**2
    if shutil.disk_usage(directory).free < required:
        raise RuntimeError('Archive volume lacks worst-case compressed capacity plus its reserve; source preserved')
    destination = directory / (path.name + '.gz')
    partial = directory / (path.name + '.gz.part-' + uuid.uuid4().hex)
    digest = hashlib.sha256()
    print(f'Preserving {before.st_size} audit bytes in {destination} ...', flush=True)
    with open(partial, 'xb') as output:
        os.chmod(partial, 0o600)
        process = subprocess.Popen(['pigz', '-1', '-p', str(c['compression_threads']), '-c'],
                                   stdin=subprocess.PIPE, stdout=output, stderr=subprocess.PIPE)
        try:
            with path.open('rb') as source:
                while chunk := source.read(4 * 1024**2):
                    digest.update(chunk)
                    process.stdin.write(chunk)
            process.stdin.close()
            if process.wait() != 0:
                raise RuntimeError('Audit compression failed; source preserved')
            output.flush()
            os.fsync(output.fileno())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    verify = hashlib.sha256()
    process = subprocess.Popen(['pigz', '-d', '-c', str(partial)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    while chunk := process.stdout.read(4 * 1024**2):
        count += len(chunk)
        verify.update(chunk)
    if process.wait() or count != before.st_size or verify.digest() != digest.digest():
        raise RuntimeError('Compressed audit readback differs; source preserved')
    after = path.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns) or open_file(c, path):
        raise RuntimeError('Closed audit changed during archival; source preserved')
    os.replace(partial, destination)
    metadata = {'source': str(path), 'archive': str(destination), 'source_bytes': count,
                'compressed_bytes': destination.stat().st_size, 'sha256': digest.hexdigest(), 'readback': 'passed'}
    atomic(str(destination) + '.json', json.dumps(metadata, indent=2) + '\n', 0o600)
    # Delete only the exact closed input after complete decompression/hash verification.
    path.unlink()
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, default=Path(__file__).with_name('protection.json'))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--discard-flood-log', action='store_true',
                        help='Discard only the closed incident audit log and its archive after verifying OpenBao released it')
    args = parser.parse_args()
    c = json.loads(args.configuration.read_text())
    if socket.gethostname().split('.')[0].lower() != c['host'].lower():
        raise RuntimeError('Wrong host for secrets protection declaration')
    http, server, site = configurations(c, Path(c['site']).read_text())
    for binary in ('nginx', 'logrotate', 'systemctl', 'curl', 'pigz'):
        if not shutil.which(binary):
            raise RuntimeError('Required installed program missing: ' + binary)
    if args.check:
        print(json.dumps({'host': c['host'], 'mode': 'configuration preflight', 'audit_log': c['audit_log'],
                          'client_rate': c['client_rate'], 'renewal_rate': c['renewal_rate'],
                          'archive': c['overflow_archive_directory']}))
        return
    if os.geteuid() != 0:
        raise RuntimeError('Run sudo ./setup.sh secrets-protection; nginx, rotation and audit ownership require root')
    with open('/run/lock/laplace-secrets-protection.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        receipt = {'host': c['host'], 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'status': 'started'}
        receipt_path = Path(c['receipt_directory']) / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + uuid.uuid4().hex[:8] + '.json')
        atomic(receipt_path, json.dumps(receipt, indent=2) + '\n')
        try:
            updates = {c['http_configuration']: http, c['server_configuration']: server, c['site']: site}
            old = {path: Path(path).read_text() if Path(path).exists() else None for path in updates}
            try:
                for path, content in updates.items():
                    atomic(path, content)
                run(['nginx', '-t'])
                run(['systemctl', 'reload', 'nginx'])
            except Exception:
                for path, content in old.items():
                    if content is None:
                        Path(path).unlink(missing_ok=True)
                    else:
                        atomic(path, content)
                run(['nginx', '-t'])
                run(['systemctl', 'reload', 'nginx'])
                raise
            # systemctl reload returns after signaling the master, before new
            # workers necessarily serve requests. Observe the actual generation.
            await_reload(c, server)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                codes = list(pool.map(lambda _: status(c, '/v1/auth/token/renew-self', 'PUT'), range(24)))
            if 429 not in codes or any(code not in (403, 429) for code in codes):
                raise RuntimeError('Live unauthenticated renewal burst did not produce the expected 403/429 boundaries: ' + str(codes))
            receipt['rate_limit'] = {str(code): codes.count(code) for code in set(codes)}
            if status(c, '/v1/sys/health') != 200:
                raise RuntimeError('OpenBao health did not pass through TLS ingress')
            closed = close_oversized_audit(c)
            stat = Path(c['audit_log']).stat()
            rotation = f'''{c['audit_log']} {{
    daily
    maxsize {c['audit_rotate_mib']}M
    rotate {c['audit_rotate_count']}
    compress
    delaycompress
    missingok
    notifempty
    create {stat.st_mode & 0o777:04o} {stat.st_uid} {stat.st_gid}
    sharedscripts
    postrotate
        /bin/systemctl kill --kill-who=main --signal=HUP {c['service']}
    endscript
}}
'''
            atomic(c['audit_rotation'], rotation)
            nginx_rotation = Path(c['nginx_rotation']).read_text()
            if nginx_rotation.count('/var/log/nginx/*.log {') != 1:
                raise RuntimeError('Unexpected nginx rotation configuration; refusing to replace it')
            nginx_rotation = re.sub(r'^\s*maxsize\s+\S+\s*$', '', nginx_rotation, flags=re.M)
            nginx_rotation = nginx_rotation.replace('/var/log/nginx/*.log {', '/var/log/nginx/*.log {\n    maxsize '+str(c['nginx_rotate_mib'])+'M')
            atomic(c['nginx_rotation'], nginx_rotation)
            run(['logrotate', '--debug', '/etc/logrotate.conf'])
            atomic('/etc/systemd/system/logrotate.timer.d/laplace-limits.conf', '[Timer]\nOnCalendar=\nOnCalendar=*-*-* *:*:00\nAccuracySec=5s\nRandomizedDelaySec=0\n')
            run(['systemctl', 'daemon-reload'])
            run(['systemctl', 'enable', '--now', 'logrotate.timer'])
            run(['systemctl', 'restart', 'logrotate.timer'])
            receipt['rotation'] = {'audit_max_mib': c['audit_rotate_mib'], 'audit_retained': c['audit_rotate_count'], 'check_interval_seconds': 60}
            receipt['archives'] = []
            atomic(receipt_path, json.dumps(receipt, indent=2) + '\n')
            if args.discard_flood_log:
                receipt['discarded_flood_files'] = discard_flood(c, closed)
            elif closed:
                raise RuntimeError('Oversized audit log closed and retained. Use --discard-flood-log to discard the incident log; automatic archival is disabled.')
            if status(c, '/v1/sys/health') != 200:
                raise RuntimeError('Final OpenBao health check failed')
            receipt['var_free_bytes'] = shutil.disk_usage(Path(c['audit_log']).parent).free
            atomic('/etc/laplace/secrets-protection.json', json.dumps(c, indent=2) + '\n')
            receipt['status'] = 'passed'
        except BaseException as error:
            receipt['status'] = 'failed'
            receipt['error'] = str(error) or type(error).__name__
            raise
        finally:
            atomic(receipt_path, json.dumps(receipt, indent=2) + '\n')
            print('Secrets protection receipt: ' + str(receipt_path), flush=True)


def discard_flood(c, closed):
    """Remove only this recovery operation's closed files, including an interrupted archive."""
    audit = Path(c['audit_log'])
    directory = Path(c['overflow_archive_directory'])
    selected = list(closed)
    pattern = re.compile(re.escape(audit.name) + r'\.recovery-[a-f0-9]{32}\.gz(?:\.json|\.part-[a-f0-9]{32})?$')
    if directory.exists():
        selected += [path for path in directory.iterdir() if pattern.fullmatch(path.name)]
    if not open_file(c, audit):
        raise RuntimeError('OpenBao is not holding the new active audit file; no incident files discarded')
    for path in selected:
        if path.is_symlink() or not path.is_file() or path.resolve() == audit.resolve() or open_file(c, path):
            raise RuntimeError('Incident file is not a closed regular file: ' + str(path))
    result = []
    for path in selected:
        result.append({'path': str(path), 'bytes': path.stat().st_size})
        path.unlink()
    return result


if __name__ == '__main__':
    main()
