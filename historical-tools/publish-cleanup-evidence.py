"""Preserve reviewed cleanup evidence on a private remote archive tag.

This does not modify main, publish runtime code, or claim platform completion.
One-off repair scripts are historical receipts, not instructions to rerun them.
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import subprocess
import tempfile

audit = Path(__file__).resolve().parent
repository = audit.parents[1] / 'Laplace-Operations'
environment = dict(os.environ)
environment['GH_TOKEN'] = subprocess.run(['gh', 'auth', 'token', '--user', 'SaltyPatron'],
    capture_output=True, text=True, check=True).stdout.strip()
private = json.loads(subprocess.run(['gh', 'repo', 'view', 'SaltyPatron/Laplace-Operations', '--json', 'isPrivate'],
    env=environment, capture_output=True, text=True, encoding='utf-8', check=True).stdout)
assert private['isPrivate'], 'Evidence archive must remain in the private owning repository.'

def git(*args, data=None, env=None):
    return subprocess.run(['git', '-C', str(repository), *args], input=data, capture_output=True,
                          env=env, check=True).stdout.strip()

assert not git('status', '--porcelain', '--untracked-files=all')
head = git('rev-parse', 'HEAD').decode()
assert git('branch', '--show-current') == b'main'
assert head == git('rev-parse', 'origin/main').decode()
names = ['repositories-current-main.json', 'merged-branch-retirement-current.json', 'main-integration-audit.json',
    'published.json', 'scratch-source-publication.json', 'server-modular-delivery-success.json',
    'server-surrogate-text-runtime.json', 'server-codepoint-runtime-readback-final.json',
    'desktop-prepared-package.json', 'desktop-prepared-input-repair.json',
    'desktop-unreadable-component-directories.json', 'desktop-client-inventory-current.json',
    'surrogate-text-candidate-probe.json', 'generated-test-output-retirement.json', 'build-output-cleanup.json',
    'fixture-cleanup.json', 'remaining-workspace-scratch-cleanup.json', 'storage-cleanup-result.json',
    'deployment-snapshot-comparison.json', 'read-path-test-database-backup.json',
    'workspace-final-scratch-audit.json', 'recovery-archives-current.json',
    'qualified-native-inputs-manifest.json', 'qualified-input-copy-retirement.json',
    'git-object-and-operation-audit.json', 'linux-installed-cleanup-final.json',
    'platform-cleanup-status.json', 'server-modular-delivery-final.json',
    'operations-package-order-final-delivery.json', 'windows-modular-build-receipt.json']
for optional in ['mono-final-delivery-success.json', 'desktop-owner-completion.json', 'platform-final-receipt.json',
                 'desktop-owner-prelaunch-current.json', 'desktop-index-catalog-preflight.json',
                 'desktop-runtime-baseline-before-upgrade.json']:
    if (audit / optional).exists():
        names.append(optional)
files = {'reports/' + name: (audit / name).read_bytes() for name in names}
for path in audit.iterdir():
    if path.is_file() and path.suffix.lower() in {'.py', '.ps1', '.cmd', '.patch'}:
        files['historical-tools/' + path.name] = path.read_bytes()
secret = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}')
for name, data in files.items():
    assert not secret.search(data), 'Credential-like content requires review: ' + name
timestamp = datetime.datetime.now(datetime.timezone.utc)
index = {'created_utc': timestamp.isoformat(), 'scope': 'Remote preservation of cleanup evidence and historical one-off tools; not a platform completion claim.',
    'operations_main': head, 'files': [{'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                                      for name, data in sorted(files.items())]}
files['index.json'] = (json.dumps(index, indent=2) + '\n').encode()
files['README.md'] = b'''# Laplace cleanup evidence

This archive preserves source reconciliation and cleanup receipts, including their
individual timestamps and scope. It does not change runtime source on main.
Only a passed platform-final-receipt.json would assert complete platform delivery.
Windows approval, installation, and access repair may still be pending in earlier
snapshots. Generated caches and recovery ZIPs remain local retained artifacts;
their receipt hashes are recorded here, not their complete payloads.

The required floor contains all 1,114,112 codepoints, including the 2,048
surrogates. Removing them was a regression; restoring that floor and preserving
their generalized UTF-8 identities is part of the implementation on main.
Historical archive labels do not supersede the corrected implementation.

Historical one-off tools document operations already taken or prepared. They are
not a supported command interface and must not be blindly rerun.
'''
with tempfile.TemporaryDirectory(prefix='laplace-evidence-index-') as directory:
    git_environment = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
    git('read-tree', '--empty', env=git_environment)
    entries = []
    for name, data in sorted(files.items()):
        blob = git('hash-object', '-w', '--stdin', data=data).decode()
        entries.append(('100644 ' + blob + '\t' + name).encode() + b'\0')
    git('update-index', '-z', '--index-info', data=b''.join(entries), env=git_environment)
    tree = git('write-tree', env=git_environment).decode()
commit = git('commit-tree', tree, '-p', head, '-F', '-',
             data=b'Preserve Laplace cleanup evidence and one-off verification tools\n\nArchive only; runtime implementation remains on main.\n').decode()
tag = 'archive/platform-cleanup-evidence-' + timestamp.strftime('%Y%m%dT%H%M%SZ')
git('tag', '-a', tag, commit, '-m', 'Cleanup evidence archive; individual receipts define verification scope.')
git('push', 'origin', 'refs/tags/' + tag)
remote = git('ls-remote', '--tags', 'origin', 'refs/tags/' + tag).decode().split()[0]
assert remote == git('rev-parse', 'refs/tags/' + tag).decode()
receipt = {'tag': tag, 'commit': commit, 'remote_tag_object': remote, 'files': len(files),
           'archive_bytes': sum(len(data) for data in files.values()), 'repository': 'SaltyPatron/Laplace-Operations'}
(audit / 'cleanup-evidence-publication.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
print(json.dumps(receipt, indent=2))
