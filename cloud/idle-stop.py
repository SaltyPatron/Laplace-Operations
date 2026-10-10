#!/usr/bin/env python3
"""Stop an explicitly configured GCE worker only after its work and leases end."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


def active_leases(attributes, now):
    active = []
    for key, value in attributes.items():
        if key != 'laplace-lease' and not key.startswith('laplace-lease-'):
            continue
        fields = value.split()
        if len(fields) != 2 or not fields[1].isdigit():
            raise ValueError('Malformed cloud lease; refusing automatic shutdown')
        if int(fields[1]) > now:
            active.append(key)
    return active


def is_work(arguments):
    if not arguments:
        return False
    name = Path(arguments[0]).name
    if name in ('Runner.Worker', 'cmake', 'ctest', 'ninja', 'make', 'icx', 'icpx',
                'gcc', 'g++', 'clang', 'clang++', 'cc1', 'cc1plus', 'ld', 'rustc'):
        return True
    if name == 'dotnet' and len(arguments) > 1 and arguments[1] in ('build', 'test', 'publish', 'restore', 'msbuild'):
        return True
    if name == 'laplace' and len(arguments) > 1 and arguments[1] in ('ingest', 'tier0', 'highway', 'deploy'):
        return True
    return any(Path(arg).name in ('deploy.sh', 'build.sh', 'ingest.sh', 'setup.sh') for arg in arguments)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--minutes', type=int, required=True)
    parser.add_argument('--check', action='store_true', help='Report without changing idle state or powering off')
    args = parser.parse_args()
    if args.minutes < 1:
        parser.error('Idle minutes must be positive')
    now = int(time.time())
    reasons = []
    if float(Path('/proc/uptime').read_text().split()[0]) < args.minutes * 60:
        reasons.append('boot grace')
    for directory in Path('/proc').glob('[0-9]*'):
        if directory.name == str(os.getpid()):
            continue
        try:
            command = directory.joinpath('cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
        except (FileNotFoundError, ProcessLookupError):
            continue
        if is_work(command):
            reasons.append('active build, test, deployment or runner')
            break
    if subprocess.check_output(['who']).strip():
        reasons.append('interactive login')
    request = urllib.request.Request(
        'http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=true',
        headers={'Metadata-Flavor': 'Google'})
    with urllib.request.urlopen(request, timeout=5) as response:
        leases = active_leases(json.load(response), now)
    if leases:
        reasons.append('active cloud lease')
    stamp = Path('/run/laplace-idle-since')
    since = int(stamp.read_text()) if stamp.exists() else now
    due = not reasons and now - since >= args.minutes * 60
    print(json.dumps({'idle_minutes': args.minutes, 'busy': reasons, 'active_leases': leases,
                      'shutdown_due': due, 'check_only': args.check}))
    if args.check:
        return
    if reasons:
        stamp.unlink(missing_ok=True)
    elif not stamp.exists():
        stamp.write_text(str(now))
    elif due:
        subprocess.run(['logger', '-t', 'laplace-idle-stop', f'Idle for {args.minutes} minutes; no active work or leases'], check=True)
        subprocess.run(['systemctl', 'poweroff'], check=True)


if __name__ == '__main__':
    main()
