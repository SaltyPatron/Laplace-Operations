"""Execute modular SQL grants in a disposable database; requires an operator connection."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('modular', ROOT / 'installation/database.py')
modular = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modular)
config = json.loads((ROOT / 'installation/hart-server-modular.json').read_text())
name = 'modular_test_' + uuid.uuid4().hex[:12]
config.update(database=name, role=name)
environment = dict(os.environ)
environment.setdefault('PGHOST',config['socket'])
environment.setdefault('PGPORT',str(config['port']))
environment.setdefault('PGUSER','laplace')


def sql(database, statement, succeeds=True):
    result = subprocess.run([os.environ.get('PSQL',str(Path(config['pgbin']) / 'psql')), '-XwAt', '-v', 'ON_ERROR_STOP=1',
                             '-d', database, '-f', '-'], input=statement, text=True,
                            capture_output=True, env=environment, timeout=180)
    if (result.returncode == 0) != succeeds:
        raise AssertionError('Unexpected SQL authorization result: ' + result.stderr)
    return result.stdout.strip()


try:
    sql('postgres', f'CREATE DATABASE "{name}" TEMPLATE template0;')
    sql(name, '''CREATE SCHEMA "native runtime"; CREATE SCHEMA "spatial runtime";
CREATE EXTENSION postgis SCHEMA "spatial runtime";
CREATE EXTENSION laplace SCHEMA "native runtime";
CREATE TABLE public.entity(id int PRIMARY KEY); INSERT INTO public.entity VALUES(17);
CREATE SCHEMA app; CREATE TABLE app.private(id int);
REVOKE ALL ON FUNCTION "native runtime".laplace_clean_pending_list(regclass) FROM PUBLIC;''')
    sql(name, modular.runtime_grants(config))
    sql(name, modular.runtime_grants(config))
    assert sql(name, f'SET SESSION AUTHORIZATION "{name}"; SELECT count(*) FROM \"native runtime\".entity;').splitlines()[-1] == '0'
    sql(name, f'''SET SESSION AUTHORIZATION "{name}"; BEGIN;
SET LOCAL session_replication_role=replica;
UPDATE "native runtime".entity SET tier=tier WHERE false;
DELETE FROM "native runtime".entity WHERE false;
TRUNCATE "native runtime".physicality,"native runtime".consensus,"native runtime".witness,"native runtime".entity;
CREATE TABLE stage.runtime_batch(id int); INSERT INTO stage.runtime_batch VALUES(1); ROLLBACK;''')
    for forbidden in ('SELECT * FROM app.private;', 'SELECT * FROM public.entity;', 'INSERT INTO public.entity VALUES(2);', 'SET ROLE laplace;',
                      'CREATE TABLE public.forbidden(id int);', 'ALTER ROLE laplace SUPERUSER;'):
        sql(name, f'SET SESSION AUTHORIZATION "{name}"; BEGIN; {forbidden} ROLLBACK;', succeeds=False)
    assert sql(name,'SELECT id FROM public.entity;')=='17'
    attributes = sql(name, f"SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname='{name}';")
    assert attributes == 'f|f|f|f|f', attributes
    print('Actual PostgreSQL grants passed: read/write/staging permitted; private schema, DDL and administrator impersonation denied; rerun idempotent.')
finally:
    sql('postgres', f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE);')
    sql('postgres', f'''DO $$ BEGIN IF EXISTS(SELECT FROM pg_roles WHERE rolname='{name}') THEN
EXECUTE 'REVOKE SET ON PARAMETER session_replication_role FROM "{name}"'; END IF; END $$;''')
    sql('postgres', f'DROP ROLE IF EXISTS "{name}";')
