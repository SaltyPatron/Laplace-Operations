"""Execute modular SQL grants in a disposable database; requires an operator connection."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('modular', ROOT / 'installation/modular.py')
modular = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modular)
config = json.loads((ROOT / 'installation/hart-server-modular.json').read_text())
name = 'modular_test_' + uuid.uuid4().hex[:12]
config.update(database=name, role=name)
environment = dict(os.environ, PGHOST=config['socket'], PGPORT=str(config['port']), PGUSER='laplace')


def sql(database, statement, succeeds=True):
    result = subprocess.run([str(Path(config['pgbin']) / 'psql'), '-XwAt', '-v', 'ON_ERROR_STOP=1',
                             '-d', database, '-f', '-'], input=statement, text=True,
                            capture_output=True, env=environment, timeout=30)
    if (result.returncode == 0) != succeeds:
        raise AssertionError('Unexpected SQL authorization result: ' + result.stderr)
    return result.stdout.strip()


try:
    sql('postgres', f'CREATE DATABASE "{name}" TEMPLATE template0;')
    sql(name, '''CREATE TABLE public.entity(id int PRIMARY KEY);
CREATE TABLE public.physicality(id int); CREATE TABLE public.consensus(id int);
CREATE TABLE public.witness(id int); CREATE SCHEMA app; CREATE TABLE app.private(id int);
INSERT INTO public.entity VALUES(1);''')
    sql(name, modular.grants(config))
    sql(name, modular.grants(config))
    assert sql(name, f'SET SESSION AUTHORIZATION "{name}"; SELECT count(*) FROM public.entity;').splitlines()[-1] == '1'
    sql(name, f'''SET SESSION AUTHORIZATION "{name}"; BEGIN;
INSERT INTO public.entity VALUES(2); UPDATE public.entity SET id=3 WHERE id=2;
DELETE FROM public.entity WHERE id=3; TRUNCATE public.entity;
CREATE TABLE stage.runtime_batch(id int); INSERT INTO stage.runtime_batch VALUES(1); ROLLBACK;''')
    for forbidden in ('SELECT * FROM app.private;', 'SET ROLE laplace;',
                      'CREATE TABLE public.forbidden(id int);', 'ALTER ROLE laplace SUPERUSER;'):
        sql(name, f'SET SESSION AUTHORIZATION "{name}"; BEGIN; {forbidden} ROLLBACK;', succeeds=False)
    attributes = sql(name, f"SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname='{name}';")
    assert attributes == 'f|f|f|f|f', attributes
    print('Actual PostgreSQL grants passed: read/write/staging permitted; private schema, DDL and administrator impersonation denied; rerun idempotent.')
finally:
    sql('postgres', f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE);')
    sql('postgres', f'DROP ROLE IF EXISTS "{name}";')
