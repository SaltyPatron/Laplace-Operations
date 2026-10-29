#!/usr/bin/env python3
"""Read kernel locks and their live descriptor owners without exposing arguments or secrets."""
import argparse
import json
import os
from pathlib import Path
import socket


def inspect(lock, proc=Path('/proc')):
    targets = {}
    for path in (lock, lock.with_name(lock.name + '.turnstile')):
        stat = path.stat()
        targets[(stat.st_dev, stat.st_ino)] = str(path)
    owners, unobservable = [], 0
    for process in proc.iterdir():
        if not process.name.isdigit():
            continue
        try:
            descriptors = []
            for descriptor in (process / 'fd').iterdir():
                try:
                    stat = descriptor.stat()
                    target = targets.get((stat.st_dev, stat.st_ino))
                    if target:
                        descriptors.append({'fd': int(descriptor.name), 'path': target})
                except FileNotFoundError:
                    pass
            if not descriptors:
                continue
            status = dict(line.split(':', 1) for line in (process / 'status').read_text().splitlines() if ':' in line)
            # Only these non-secret ownership fields enter the report. Never
            # export cmdline, the rest of environ, or arbitrary /proc contents.
            environment = dict(item.partition('=')[::2] for item in
                               (process / 'environ').read_text().split('\0') if '=' in item)
            owners.append({'pid': int(process.name), 'parent_pid': int(status['PPid']),
                           'uid': int(status['Uid'].split()[0]), 'name': (process / 'comm').read_text().strip(),
                           'executable': os.readlink(process / 'exe'), 'descriptors': descriptors,
                           'job': {key: environment[key] for key in
                                   ('GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_JOB', 'RUNNER_NAME') if key in environment}})
        except (FileNotFoundError, ProcessLookupError):
            pass
        except PermissionError:
            unobservable += 1
    keys = [f'{os.major(device):02x}:{os.minor(device):02x}:{inode}' for device, inode in targets]
    kernel = [line for line in (proc / 'locks').read_text().splitlines() if any(key in line.split() for key in keys)]
    return {'host': socket.gethostname(), 'observer_uid': os.geteuid(), 'locks': list(targets.values()),
            'kernel_locks': kernel, 'descriptor_owners': owners, 'unobservable_processes': unobservable}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.configuration.read_text())
    if config['host'].lower() != socket.gethostname().lower():
        raise ValueError('The host-lock declaration belongs to another host')
    lock = Path(config['lock'])
    if not lock.is_absolute() or '..' in lock.parts or not args.output.is_absolute():
        raise ValueError('Declare absolute lock and report paths')
    report = inspect(lock)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
