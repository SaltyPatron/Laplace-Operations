"""Read back the installed desktop Native floor and preserve upgrade evidence."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import subprocess
import sys

audit = Path(__file__).resolve().parent
root = audit.parents[1]
sys.path.insert(0, str(root / 'Laplace-Operations/installation'))
import client

owner = json.loads((audit / 'desktop-owner-completion.json').read_text(encoding='utf-8-sig'))
installed_readback = json.loads((audit / 'desktop-all-installed-readback.json').read_text(encoding='utf-8-sig'))
modular_delivery = json.loads((audit / 'desktop-modular-deployment.json').read_text(encoding='utf-8-sig'))
assert len(owner['repaired']) == 23 and installed_readback['passed'], (owner, installed_readback)
assert len(modular_delivery['steps']) == 3 and all(s['status'] == 'passed' for s in modular_delivery['steps']), modular_delivery
config = json.loads((root / 'Laplace-Operations/installation/hart-desktop-operator.json').read_text())
target = next(t for t in config['targets'] if t.get('authentication') == 'sspi')
environment = {k: v for k, v in os.environ.items() if not k.upper().startswith('PG')}
environment.update(PGHOST=target['host'], PGHOSTADDR='127.0.0.1', PGPORT=str(target['port']),
    PGUSER=config['role'], PGSSLMODE='verify-full', PGREQUIREAUTH='sspi',
    PGSSLROOTCERT=str(Path(config['state']) / 'hart-desktop-postgresql.crt'),
    PGPASSFILE=str(Path(config['state']) / 'unused-no-password-file'), PGCONNECT_TIMEOUT='10')
sql = """BEGIN READ ONLY; SET LOCAL statement_timeout='45s'; SELECT jsonb_build_object(
  'extension_version',(SELECT extversion FROM pg_catalog.pg_extension WHERE extname='laplace'),
  'identity',(SELECT jsonb_build_object('role',current_user,'system_user',system_user,'tls',ssl)
    FROM pg_catalog.pg_stat_ssl WHERE pid=pg_catalog.pg_backend_pid()),
  'functions',(SELECT jsonb_agg(jsonb_build_object('oid',p.oid::text,'schema',n.nspname,'name',p.proname,
    'arguments',pg_catalog.pg_get_function_identity_arguments(p.oid),'module',p.probin) ORDER BY p.oid)
    FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('laplace_cp_id','laplace_id','laplace_restore_function_bindings')),
  'surrogates',(SELECT jsonb_build_object('count',count(*),'roundtrips',bool_and(public.laplace_codepoint(public.laplace_cp_id(cp))=cp),
    'coordinates',bool_and(octet_length(public.laplace_cp_coord_ewkb(cp))=37))
    FROM pg_catalog.generate_series(55296,57343) cp),
  'boundaries',(SELECT jsonb_agg(jsonb_build_object('cp',cp,'reverse',public.laplace_codepoint(public.laplace_cp_id(cp)),
    'id',public.laplace_cp_id(cp)::text,'coordinate_bytes',octet_length(public.laplace_cp_coord_ewkb(cp))))
    FROM unnest(ARRAY[55295,55296,56319,56320,57343,57344,1114111]) cp),
  'cache_settings',(SELECT jsonb_object_agg(name,setting) FROM pg_catalog.pg_settings
    WHERE name IN ('laplace.tier0','laplace.flags','laplace.highway'))); ROLLBACK;"""
baseline = {d['database']: d for d in json.loads((audit / 'desktop-native-bindings-before-upgrade.json').read_text())['databases']}
result = {'checked_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'databases': []}
expected = {55296: 'dff435ed8113f31233474261aa854f0f', 56319: 'fa5a060c1e71a595d3f2595f8783c6ed',
            56320: 'ccb958508a431b01ad9484e67d820e09', 57343: '12501a6725d76de9a6d1c78f69fd2517'}
for database in ['laplace', 'laplace-mono']:
    process = subprocess.run([str(Path(target['prefix']) / 'bin/psql.exe'), '-X', '-A', '-t', '-w',
        '-v', 'ON_ERROR_STOP=1', '-d', database, '-c', sql], env=environment,
        capture_output=True, text=True, encoding='utf-8', check=True, timeout=60)
    live = next(json.loads(line) for line in process.stdout.splitlines() if line.startswith('{'))
    assert live['extension_version'] == '1.61', (database, live)
    assert live['identity']['role'] == config['role'] and live['identity']['tls'], live
    assert live['surrogates'] == {'count': 2048, 'roundtrips': True, 'coordinates': True}, live
    assert all(cp['cp'] == cp['reverse'] and cp['coordinate_bytes'] == 37 and
               expected.get(cp['cp'], cp['id']) == cp['id'] for cp in live['boundaries']), live
    before = {(f['schema'], f['name'], f['arguments']): f for f in baseline[database]['functions']}
    assert len(live['functions']) == len(before), live
    for function in live['functions']:
        old = before[(function['schema'], function['name'], function['arguments'])]
        assert function['oid'] == old['oid'] and function['module'] != old['module'], (old, function)
    live['function_oids_preserved'] = True
    live['database'] = database
    result['databases'].append(live)

executable, selected_environment, description = client.selected(Path('E:/Data/Laplace/clients/laplace/client.json'))
installed_environment = client.process_environment(selected_environment)
installed_environment['PATH'] = str(executable.parent) + os.pathsep + str(Path(os.environ['SystemRoot']) / 'System32')
client.verify_engine(executable, installed_environment)
result['modular_mcp'] = client.verify_mcp(executable, installed_environment, database=description['database'])
transport = subprocess.run([sys.executable, str(root / 'Laplace-MCP/tests/json-arguments.py'),
    str(executable.with_name('lpm.exe'))], env=installed_environment,
    capture_output=True, text=True, encoding='utf-8', check=True, timeout=45)
result['mcp_unicode_transport'] = {'status': 'passed', 'result': transport.stdout.strip()}
result['selection'] = description
cache = Path(selected_environment['LAPLACE_TIER0'])
result['selected_cache'] = {'path': str(cache), 'bytes': cache.stat().st_size,
                          'sha256': hashlib.sha256(cache.read_bytes()).hexdigest()}
assert result['selected_cache']['bytes'] == 1114112 * 64, result['selected_cache']
assert result['selected_cache']['sha256'] == '053feae171eaf496b4c5bc6a7ae3615cf8d7632dfae5b31436c3872fa4be83d1', result['selected_cache']
result['status'] = 'passed'
path = audit / 'desktop-codepoint-runtime-readback-final.json'
path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'status': result['status'], 'receipt': str(path), 'release': description['release'],
    'checks': ['Native 1.61 in both substrates', 'all 2048 surrogate roundtrips and coordinates',
               'function OIDs preserved', 'installed Engine and MCP readback', 'complete floor cache hash']}, indent=2))
