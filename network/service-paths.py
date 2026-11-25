"""Check the browser entry points without credentials or following OAuth redirects."""
import argparse
import datetime
import json
import platform
import socket
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(opener, url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Laplace-Ops-Probe/1.0'})
    try:
        response = opener.open(req, timeout=12)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.code, response.headers, response.read(2 * 1024 * 1024)


def verify(route):
    base = route['browser_origin'].rstrip('/')
    uri = urllib.parse.urlsplit(base)
    if uri.scheme not in ('http', 'https') or not uri.hostname or uri.path or uri.query or uri.fragment or uri.username:
        raise ValueError('browser_origin must be an HTTP(S) origin without credentials or a path')
    result = dict(environment=route['environment'], browser_origin=base, checks=[], passed=False)
    def check(name, passed, **details):
        result['checks'].append(dict(name=name, passed=bool(passed), **details))
    check('browser_tls', uri.scheme == 'https')
    opener = urllib.request.build_opener(NoRedirect())
    try:
        result['addresses'] = sorted({r[4][0] for r in socket.getaddrinfo(uri.hostname, uri.port or (443 if uri.scheme == 'https' else 80))})
        for path, name in (('/', 'ui'), ('/health', 'api_health')):
            status, headers, body = request(opener, base + path)
            valid = status == 200
            if name == 'ui':
                valid = valid and 'text/html' in headers.get('Content-Type', '') and b'<div id="root"' in body
            else:
                try:
                    health = json.loads(body)
                    valid = valid and health.get('status') == 'ok' and health.get('stream') == 'laplace'
                except (ValueError, AttributeError):
                    valid = False
            check(name, valid, status=status, server=headers.get('Server'))
        status, _, body = request(opener, base + '/v1/auth/config')
        auth = json.loads(body) if status == 200 else {}
        providers = {p['id']: p for p in auth.get('providers', [])}
        check('sign_in_providers', status == 200 and all(p in providers for p in route['providers']), status=status)
        for provider in route['providers']:
            status, headers, _ = request(opener, base + '/v1/auth/login/' + provider)
            destination = urllib.parse.urlsplit(headers.get('Location', ''))
            callback = urllib.parse.parse_qs(destination.query).get('redirect_uri', [None])[0]
            expected = base + '/signin-' + provider
            # Persist only the callback; Location also contains transient OAuth state.
            check(provider + '_callback', status == 302 and callback == expected,
                  status=status, callback=callback, expected=expected)
    except Exception as error:
        # Response bodies and authentication query strings are never stored.
        check('route_reachable', False, error_type=type(error).__name__)
    result['passed'] = all(c['passed'] for c in result['checks'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, default=Path(__file__).with_name('environments.json'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('refusing to overwrite an existing receipt')
    configuration = json.loads(args.configuration.read_text(encoding='utf-8-sig'))
    routes = configuration.get('routes')
    if routes is None:
        routes = [dict(environment=e['name'], browser_origin=e['browser_origin'],
                       providers=list(configuration['providers'])) for e in configuration['environments']]
    results = [verify(route) for route in routes]
    receipt = dict(host=platform.node(), observed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   scope='Browser routes, TLS and OAuth callback construction; excludes provider registration and authenticated product behavior',
                   routes=results, passed=all(r['passed'] for r in results))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    for result in results:
        failures = ', '.join(c['name'] for c in result['checks'] if not c['passed'])
        print(f"{result['environment']}: {result['browser_origin']} {'passed' if result['passed'] else 'FAILED: ' + failures}")
    print(f'Receipt: {args.output}')
    raise SystemExit(0 if receipt['passed'] else 1)


if __name__ == '__main__':
    main()
