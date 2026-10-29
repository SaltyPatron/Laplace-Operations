"""Portable SQL ownership for the declared modular database identity."""


def runtime_grants(config):
    role, database = config['role'], config['database']
    return f'''BEGIN;
DO $$ BEGIN
 IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='{role}') THEN CREATE ROLE "{role}" LOGIN; END IF;
 IF EXISTS (SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='{role}')) THEN
  RAISE EXCEPTION 'Dedicated modular role already has memberships'; END IF;
END $$;
ALTER ROLE "{role}" NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT {config['connection_limit']};
GRANT CONNECT,TEMPORARY ON DATABASE "{database}" TO "{role}";
GRANT SET ON PARAMETER session_replication_role TO "{role}";
CREATE SCHEMA IF NOT EXISTS stage;
GRANT USAGE,CREATE ON SCHEMA stage TO "{role}";
GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,MAINTAIN ON ALL TABLES IN SCHEMA stage TO "{role}";
DO $$ DECLARE item record; native name; BEGIN
 SELECT n.nspname INTO STRICT native FROM pg_catalog.pg_extension e
 JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='laplace';
 -- The dedicated runtime never inherits access to unrelated public tables.
 REVOKE SELECT,INSERT,UPDATE,DELETE,TRUNCATE,MAINTAIN ON ALL TABLES IN SCHEMA public FROM "{role}";
 FOR item IN SELECT DISTINCT n.nspname FROM pg_catalog.pg_extension e
  JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace WHERE e.extname IN ('laplace','postgis')
 LOOP EXECUTE format('GRANT USAGE ON SCHEMA %I TO "{role}"',item.nspname); END LOOP;
 EXECUTE format('GRANT EXECUTE ON FUNCTION %I.laplace_clean_pending_list(regclass) TO "{role}"',native);
 FOR item IN SELECT c.oid::regclass relation FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_depend d ON d.classid='pg_catalog.pg_class'::regclass AND d.objid=c.oid AND d.deptype='e'
  JOIN pg_catalog.pg_extension e ON e.oid=d.refobjid AND e.extname='laplace'
  WHERE c.relkind IN ('r','p')
 LOOP EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,MAINTAIN ON TABLE %s TO "{role}"',item.relation); END LOOP;
END $$;
COMMIT;
'''

