"""Publish the declared local extension and upgrade its existing database."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def prepare(config, release, run):
    source, build = Path(config['postgres']), Path(config['postgres_build'])
    pg_config = Path(config['postgres_prefix']) / 'bin/pg_config.exe'
    run(['cmake', '-S', source, '-B', build,
         '-DLAPLACE_NATIVE=' + config['native'], '-DPG_CONFIG=' + str(pg_config)])
    run(['cmake', '--build', build, '--target', 'laplace_pg'])
    output = release / 'share/postgres'
    output.mkdir(parents=True)
    shutil.copy2(build / 'laplace.dll', output / 'laplace.dll')
    shutil.copy2(source / 'laplace.control', output / 'laplace.control')
    for sql in source.glob('sql/laplace--*.sql'):
        shutil.copy2(sql, output / sql.name)
    return output


def replace(path, data, config, run):
    """Replace complete files; never truncate a loaded server library."""
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.laplace-install-', delete=False) as stream:
        pending = Path(stream.name)
        stream.write(data)
    try:
        run(['icacls.exe', pending, '/inheritance:e', '/grant',
             '*' + config['operator_client']['windows_sid'] + ':(F)',
             '*' + config['database_artifact_reader'] + ':(RX)'])
        os.replace(pending, path)
    finally:
        pending.unlink(missing_ok=True)


def install(config, package, environment, fingerprints, run):
    prefix = Path(config['postgres_prefix'])
    pg_config = prefix / 'bin/pg_config.exe'
    library = Path(run([pg_config, '--pkglibdir'])) / 'laplace.dll'
    scripts = Path(run([pg_config, '--sharedir'])) / 'extension'
    if not library.is_relative_to(prefix) or not scripts.is_relative_to(prefix):
        raise ValueError('Extension destinations differ from the declared PostgreSQL prefix')
    if library.exists():
        # The operation never terminates a backend or restarts PostgreSQL.
        # A loaded/inaccessible library fails before any server files change.
        descriptor = os.open(library, os.O_RDWR)
        os.close(descriptor)
    replacements = [(library, package / 'laplace.dll')]
    replacements.extend((scripts / item.name, item) for item in sorted(package.glob('laplace--*.sql')))
    replacements.append((scripts / 'laplace.control', package / 'laplace.control'))
    previous = [(target, target.read_bytes() if target.exists() else None) for target, _ in replacements]
    options = []
    for name in ['tier0', 'flags', 'highway']:
        value = environment['LAPLACE_' + name.upper()].replace('\\', '/')
        value = ''.join('\\' + c if c.isspace() or c == '\\' else c for c in value)
        options.extend(['-c', 'laplace.' + name + '=' + value])
    environment = dict(environment, PGOPTIONS=' '.join(options))
    psql = [prefix / 'bin/psql.exe', '-X', '-A', '-t',
            '-d', environment['LAPLACE_CONNINFO'], '-v', 'ON_ERROR_STOP=1']
    arguments = list(psql)
    for name in ['tier0', 'flags', 'highway']:
        arguments.extend(['-v', name + '=' + environment['LAPLACE_' + name.upper()]])
    for name in ['tier0', 'highway']:
        arguments.extend(['-v', 'expected_' + name + '=' + fingerprints[name]])
    sql = r"""
BEGIN;
ALTER EXTENSION laplace UPDATE;
SELECT laplace_fingerprint() = :'expected_tier0'
   AND laplace_highway_fingerprint() = :'expected_highway' AS compatible \gset
\if :compatible
ALTER DATABASE :"DBNAME" SET laplace.tier0 TO :'tier0';
ALTER DATABASE :"DBNAME" SET laplace.flags TO :'flags';
ALTER DATABASE :"DBNAME" SET laplace.highway TO :'highway';
SELECT 'extension=' || extversion FROM pg_extension WHERE extname = 'laplace';
COMMIT;
\else
ROLLBACK;
SELECT 1/0;
\endif
"""
    attempted = False
    try:
        for target, source in replacements:
            replace(target, source.read_bytes(), config, run)
        attempted = True
        result = subprocess.run(list(map(str, arguments)), input=sql, env=environment,
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Existing-database extension upgrade failed: ' + result.stderr)
        print(result.stdout.strip())
    except BaseException:
        if attempted:
            # A client error after COMMIT must not restore an older DLL beneath
            # a database that already accepted this release.
            inspect = subprocess.run(list(map(str, psql)) + ['-c',
                "SELECT coalesce(jsonb_object_agg(split_part(c,'=',1),substr(c,strpos(c,'=')+1)),'{}')"
                " FROM pg_db_role_setting s CROSS JOIN LATERAL unnest(s.setconfig) c"
                " WHERE s.setdatabase=(SELECT oid FROM pg_database WHERE datname=current_database())"
                " AND s.setrole=0 AND (c LIKE 'laplace.tier0=%' OR c LIKE 'laplace.highway=%')"],
                env=environment, capture_output=True, text=True)
            if inspect.returncode:
                raise RuntimeError('Extension publication requires database-state reconciliation; server files retained')
            selected = json.loads(inspect.stdout)
            if selected == {'laplace.tier0': environment['LAPLACE_TIER0'],
                            'laplace.highway': environment['LAPLACE_HIGHWAY']}:
                raise RuntimeError('Database accepted the extension; server files retained for this release')
        for target, data in reversed(previous):
            if data is None:
                target.unlink(missing_ok=True)
            else:
                replace(target, data, config, run)
        raise
