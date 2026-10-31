from pathlib import Path
import datetime
import json
import subprocess

audit = Path(__file__).resolve().parent
script = '''from pathlib import Path
import hashlib,json,subprocess,socket
psql=['/usr/local/pgsql/bin/psql','-X','-A','-t','-h','/tmp','-U','laplace','-v','ON_ERROR_STOP=1']
results=[]
for database in ['laplace','laplace-mono']:
    sql="""BEGIN READ ONLY; SET LOCAL statement_timeout='45s'; SELECT jsonb_build_object(
      'extension_version',(SELECT extversion FROM pg_catalog.pg_extension WHERE extname='laplace'),
      'functions',(SELECT jsonb_agg(jsonb_build_object('oid',p.oid::text,'schema',n.nspname,'name',p.proname,
        'arguments',pg_catalog.pg_get_function_identity_arguments(p.oid),'module',p.probin) ORDER BY p.oid)
        FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname IN ('laplace_cp_id','laplace_id','laplace_restore_function_bindings')),
      'codepoints',(SELECT jsonb_agg(jsonb_build_object('cp',cp,'reverse',public.laplace_codepoint(public.laplace_cp_id(cp)),
        'id',public.laplace_cp_id(cp)::text,'coordinate_bytes',octet_length(public.laplace_cp_coord_ewkb(cp))))
        FROM unnest(ARRAY[55295,55296,56319,56320,57343,57344,1114111]) cp)); ROLLBACK;"""
    p=subprocess.run(psql+['-d',database,'-c',sql],capture_output=True,text=True)
    results.append({'database':database,'exit':p.returncode,
      'result':[json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')],'error':p.stderr.strip()})
cache=Path('/opt/laplace/share/laplace/tier0.bin')
print(json.dumps({'host':socket.gethostname(),'databases':results,'global_prepared':{'path':str(cache),
  'bytes':cache.stat().st_size,'sha256':hashlib.sha256(cache.read_bytes()).hexdigest()}},indent=2))
'''
process = subprocess.run(['ssh', '-o', 'BatchMode=yes', 'hart-server', 'python3 -'],
                         input=script, capture_output=True, text=True, encoding='utf-8', check=True)
result = json.loads(process.stdout)
result['checked_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
expected = {55296: 'dff435ed8113f31233474261aa854f0f', 56319: 'fa5a060c1e71a595d3f2595f8783c6ed',
            56320: 'ccb958508a431b01ad9484e67d820e09', 57343: '12501a6725d76de9a6d1c78f69fd2517'}
checks = []
for database in result['databases']:
    assert database['exit'] == 0, database
    live = database['result'][0]
    assert live['extension_version'] == '1.61', database
    assert len(live['codepoints']) == 7, database
    assert all(cp['cp'] == cp['reverse'] and cp['coordinate_bytes'] == 37 for cp in live['codepoints']), database
    assert all(expected.get(cp['cp'], cp['id']) == cp['id'] for cp in live['codepoints']), database
    if database['database'] == 'laplace-mono':
        before = json.loads((audit / 'mono-native-binding-before-upgrade.json').read_text())
        before_functions = {f['name']: f for f in before['functions']}
        assert len(live['functions']) == len(before_functions), database
        for function in live['functions']:
            assert function['oid'] == before_functions[function['name']]['oid'], function
            assert function['module'].removeprefix('$libdir/') != before_functions[function['name']]['module'], function
        checks.append('populated laplace-mono function OIDs preserved and Native module replaced')
    checks.append(database['database'] + ': extension 1.61; codepoint reverse, Native IDs, and coordinate readback passed')
assert result['global_prepared']['bytes'] == 1114112 * 64, result
assert result['global_prepared']['sha256'] == '053feae171eaf496b4c5bc6a7ae3615cf8d7632dfae5b31436c3872fa4be83d1', result
result.update(status='passed', checks=checks)
(audit / 'server-codepoint-runtime-readback-final.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'status': result['status'], 'checks': checks, 'receipt': str(audit / 'server-codepoint-runtime-readback-final.json')}, indent=2))
