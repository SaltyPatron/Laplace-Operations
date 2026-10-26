#!/usr/bin/env python3
"""Read the installed Native caches and the admitted database; never repair either."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    if result.returncode:
        # Do not include command arguments: the connection may contain credentials.
        raise RuntimeError(result.stderr.strip() or f"Readback exited {result.returncode}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    suffix = '.exe' if os.name == 'nt' else ''
    parser.add_argument('--engine', default=os.environ.get('LAPLACE_PROGRAM') or
                        str(Path(os.environ.get('LAPLACE_BUILD', '/repos/build')) /
                            'Laplace-Engine' / 'icx-release' / ('laplace' + suffix)))
    parser.add_argument('--psql', default=str(Path(os.environ.get('LAPLACE_PG_DIR', '/usr/local/pgsql')) /
                                           'bin' / ('psql' + suffix)))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = {
        'schema': 1,
        'host': socket.gethostname(),
        'started_at': datetime.now(timezone.utc).isoformat(),
        'trigger_run': os.environ.get('LAPLACE_AUDIT_TRIGGER_RUN'),
        'auditor_revision': os.environ.get('LAPLACE_AUDITOR_REVISION'),
        'passed': False,
    }
    try:
        text = run([args.engine, 'text', 'a'])
        highway = run([args.engine, 'highway', '--fingerprint'])
        tier0_match = re.search(r'^tier 0\s+([0-9a-f]{64})\b', text, re.M)
        highway_match = re.search(r'^fingerprint\s+([0-9a-f]{64})\b', highway, re.M)
        if not tier0_match or not highway_match:
            raise RuntimeError('Installed Engine did not report both cache fingerprints')
        probe = run([args.engine, 'text', 'mississippi'])
        probe_match = re.search(r'^entity\s+([0-9a-f]{32})\s+tier\s+(\d+)\b', probe, re.M)
        if not probe_match:
            raise RuntimeError('Installed Engine did not report the canonical text probe')
        native = run([args.engine, 'ingest', '--highway', '--no-load'])
        (args.output / 'native-highway.txt').write_text(native, encoding='utf-8')
        if 'highway contents validated; no database access:' not in native:
            raise RuntimeError('Installed Native highway validation did not complete')
        receipt['native_highway_validated'] = True
        sql = Path(__file__).resolve().parent / 'sql' / 'verify-admitted-data.sql'
        database = json.loads(run([args.psql, '-XwqAt', '-v', 'ON_ERROR_STOP=1',
                                   '--dbname', os.environ.get('LAPLACE_CONNINFO', ''), '-f', str(sql)]))
        receipt['database'] = database
        receipt['checks'] = {
            'has_admitted_content': database['entities'] > 0 and (database['maximum_tier'] or 0) > 0,
            'has_admitted_witnesses': bool(database['witnesses']),
            'tier0_matches_engine': database['tier0'] == tier0_match.group(1),
            'highway_matches_engine': database['highway'] == highway_match.group(1),
            'canonical_text_matches_engine': database['canonical_text_probe'] == {
                'id': probe_match.group(1), 'tier': int(probe_match.group(2))},
            'parent_heights_exceed_children': database['edges']['height_violations'] == 0,
            'all_paths_have_entities': database['physicality']['paths_without_entity'] == 0,
            'path_heights_match_entities': database['physicality']['path_height_mismatches'] == 0,
            'all_references_resolve': database['closure']['unresolved_references'] == 0,
        }
        receipt['passed'] = all(receipt['checks'].values())
    except (RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError, OSError) as error:
        receipt['error'] = str(error) if not isinstance(error, subprocess.TimeoutExpired) else 'Readback timed out'
    receipt['finished_at'] = datetime.now(timezone.utc).isoformat()
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    database = receipt.get('database', {})
    print(json.dumps({'passed': receipt['passed'], 'receipt': str(args.output / 'receipt.json'),
                      'entities': database.get('entities'), 'maximum_tier': database.get('maximum_tier'),
                      'checks': receipt.get('checks'), 'error': receipt.get('error')}))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as stream:
            stream.write('## Admitted data readback\n\n')
            stream.write(f"Result: {'passed' if receipt['passed'] else 'failed'}. "
                         f"Exact entities: {database.get('entities')}; maximum tier: {database.get('maximum_tier')}.\n\n")
            stream.write('| Check | Passed |\n|---|---|\n')
            for name, passed in receipt.get('checks', {}).items():
                stream.write(f'| {name} | {passed} |\n')
            if receipt.get('error'):
                stream.write('\nReadback failed; see the retained receipt and job error.\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
