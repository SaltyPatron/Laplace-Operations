"""Install the declared private HTTPS browser route using the existing certificate."""
import argparse
import ipaddress
import json
import os
import re
import socket
import subprocess
import urllib.parse
from pathlib import Path


def render(config):
    origin = urllib.parse.urlsplit(config['browser_origin'])
    if origin.scheme != 'https' or origin.path or origin.query or origin.fragment or origin.username or not re.fullmatch(r'[a-z0-9.-]+', origin.hostname):
        raise ValueError('The browser origin must be a named HTTPS origin')
    address = str(ipaddress.IPv4Address(config['listen_address']))
    allows = '\n    '.join('allow ' + str(ipaddress.ip_network(n, strict=False)) + ';' for n in config['allowed_networks'])
    for name in ('certificate', 'certificate_key'):
        if not re.fullmatch(r'/[A-Za-z0-9_./-]+', config[name]) or '..' in Path(config[name]).parts:
            raise ValueError('Invalid certificate path')
    locations = []
    for location, key in (('/', 'api_upstream'), ('= /mcp', 'mcp_upstream')):
        upstream = urllib.parse.urlsplit(config[key])
        if upstream.scheme != 'http' or upstream.hostname not in ('127.0.0.1', '::1') or not upstream.port or upstream.path or upstream.query or upstream.fragment or upstream.username:
            raise ValueError('A private browser route must use the declared loopback service')
        locations.append(f'''    location {location} {{
        proxy_pass {config[key]};
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }}''')
    return f'''# Managed by Laplace-Operations network/install-nginx.py.
server {{
    listen {address}:{origin.port or 443} ssl http2;
    server_name {origin.hostname};
    ssl_certificate {config['certificate']};
    ssl_certificate_key {config['certificate_key']};
    ssl_protocols TLSv1.2 TLSv1.3;
    {allows}
    deny all;
    client_max_body_size 256m;
{chr(10).join(locations)}
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, default=Path(__file__).with_name('environments.json'))
    parser.add_argument('--environment')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    environments = json.loads(args.configuration.read_text())['environments']
    matches = [e for e in environments if (e['name'] == args.environment if args.environment else
               e['host'].lower() == socket.gethostname().split('.')[0].lower() and e['hosting'] == 'nginx')]
    if not matches and not args.environment:
        print('No private nginx browser route declared for this host.')
        return
    if len(matches) != 1:
        raise SystemExit('Select exactly one declared nginx environment.')
    config = matches[0]
    if config['hosting'] != 'nginx':
        raise SystemExit('This installation operation is for a declared nginx environment.')
    content = render(config)
    if not args.apply:
        print(content, end='')
        return
    if os.geteuid() != 0 or socket.gethostname().split('.')[0].lower() != config['host'].lower():
        raise SystemExit('Apply requires root on the declared installation host.')
    hostname = urllib.parse.urlsplit(config['browser_origin']).hostname
    coverage = subprocess.run(['openssl', 'x509', '-in', config['certificate'], '-noout', '-checkhost', hostname],
                              check=True, capture_output=True, text=True)
    if 'Certificate matches host ' not in coverage.stdout:
        raise SystemExit('The existing certificate does not cover the declared browser hostname.')
    subprocess.run(['openssl', 'x509', '-in', config['certificate'], '-noout', '-checkend', '86400'], check=True)
    target = Path('/etc/nginx/sites-available/laplace-browser')
    enabled = Path('/etc/nginx/sites-enabled/laplace-browser')
    if enabled.is_symlink() and enabled.resolve() != target:
        raise SystemExit('The browser site link belongs to another configuration.')
    if enabled.exists() and not enabled.is_symlink():
        raise SystemExit('The browser site entry is not an installer-owned symlink.')
    if target.exists() and not target.read_text().startswith('# Managed by Laplace-Operations network/install-nginx.py.'):
        raise SystemExit('The browser configuration belongs to another installer.')
    before = target.read_bytes() if target.exists() else None
    was_enabled = enabled.is_symlink()
    try:
        target.write_text(content)
        target.chmod(0o644)
        if not was_enabled:
            enabled.symlink_to(target)
        subprocess.run(['nginx', '-t'], check=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
        # Exercise TLS hostname validation and the named virtual host without
        # depending on DNS propagation on this installation machine.
        origin = urllib.parse.urlsplit(config['browser_origin'])
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--max-time', '15',
                        '--resolve', f'{hostname}:{origin.port or 443}:{config["listen_address"]}',
                        config['browser_origin'] + '/health'], check=True)
    except Exception:
        if before is None:
            target.unlink(missing_ok=True)
        else:
            target.write_bytes(before)
        if not was_enabled:
            enabled.unlink(missing_ok=True)
        subprocess.run(['nginx', '-t'], check=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
        raise
    print('\nInstalled and reached ' + config['browser_origin'])


if __name__ == '__main__':
    main()
