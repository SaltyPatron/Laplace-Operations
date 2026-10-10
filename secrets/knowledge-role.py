#!/usr/bin/env python3
"""Provision a database-scoped runtime login and one TLS-only client HBA rule.

Run over the database host's authorized local administration connection. The
credential record is JSON on stdin; neither passwords nor SQL are printed.
"""
import fcntl
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    config = json.load(sys.stdin)
    database, role = config["database"], config["role"]
    if not all(re.fullmatch(r"[a-z][a-z0-9_-]*", name) for name in (database, role)):
        raise ValueError("Invalid database or role")
    if not re.fullmatch(r"[0-9a-f]{64}", config["password"]):
        raise ValueError("Expected a generated runtime credential")
    client = ipaddress.ip_address(config["client_address"])
    lock = open(config["lock"], "a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    arguments = [config["psql"], "-X", "-w", "-v", "ON_ERROR_STOP=1", "-At",
                 "-h", config["admin_socket"], "-p", str(int(config["port"])), "-U", config["admin_role"], "-d", database]

    def sql(statement):
        result = subprocess.run(arguments, input=statement, text=True, capture_output=True, timeout=30)
        if result.returncode:
            # PostgreSQL can include the offending statement in diagnostics.
            raise RuntimeError("Database provisioning failed; inspect the database server log")
        return result.stdout.strip()

    existing = sql("SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls "
                   "FROM pg_roles WHERE rolname=" + literal(role))
    if existing == "t":
        raise ValueError("Refusing to repurpose a privileged database role")
    quoted_role = '"' + role + '"'
    statements = ["BEGIN", "SET LOCAL lock_timeout='10s'"]
    if not existing:
        statements.append("CREATE ROLE " + quoted_role + " LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                          "NOREPLICATION NOBYPASSRLS PASSWORD " + literal(config["password"]))
    statements.append('GRANT CONNECT ON DATABASE "' + database + '" TO ' + quoted_role)
    schemas = sql("SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' "
                  "AND nspname NOT IN ('information_schema','app') ORDER BY nspname").splitlines()
    for schema in schemas:
        quoted_schema = '"' + schema.replace('"', '""') + '"'
        statements.extend([
            "GRANT USAGE ON SCHEMA " + quoted_schema + " TO " + quoted_role,
            "GRANT " + ("SELECT" if schema == "public" else "SELECT,INSERT,UPDATE,DELETE") + " ON ALL TABLES IN SCHEMA " + quoted_schema + " TO " + quoted_role,
            "GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA " + quoted_schema + " TO " + quoted_role,
            "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA " + quoted_schema + " TO " + quoted_role,
        ])
        if schema != "public":
            statements.extend([
                'ALTER DEFAULT PRIVILEGES FOR ROLE "' + config["admin_role"] + '" IN SCHEMA ' + quoted_schema +
                " GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO " + quoted_role,
                'ALTER DEFAULT PRIVILEGES FOR ROLE "' + config["admin_role"] + '" IN SCHEMA ' + quoted_schema +
                " GRANT USAGE,SELECT ON SEQUENCES TO " + quoted_role,
            ])
    statements.append("COMMIT")
    sql(";\n".join(statements) + ";")

    hba = Path(sql("SHOW hba_file"))
    remote = hba.with_name("pg_hba.remote.conf")
    original = json.loads(sql("SELECT to_json(pg_read_file(" + literal(str(hba)) + "))"))
    previous = json.loads(sql("SELECT to_json(COALESCE(pg_read_file(" + literal(str(remote)) + ",0,1048576,true),''))"))
    rule = f"hostssl {database} {role} {client}/{client.max_prefixlen} scram-sha-256"
    updated_remote = previous if rule in previous.splitlines() else previous.rstrip() + "\n" + rule + "\n"
    include = "include_if_exists pg_hba.remote.conf"
    updated_hba = original if include in original.splitlines() else include + "\n" + original

    def write(path, content):
        # COPY's text representation escapes backslashes. Refuse an HBA using
        # continuation/escape syntax rather than silently changing its meaning.
        if "\\" in content or "\x00" in content:
            raise ValueError("Existing HBA uses escaping; preserve it for an explicit administrator update")
        sql("COPY (SELECT unnest(string_to_array(" + literal(content.rstrip("\n")) + ", E'\\n'))) TO " + literal(str(path)))

    try:
        if updated_remote != previous:
            write(remote, updated_remote)
        if updated_hba != original:
            write(hba, updated_hba)
        if sql("SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL") != "0":
            raise ValueError("Generated HBA did not validate")
        if sql("SELECT pg_reload_conf()") != "t":
            raise ValueError("PostgreSQL did not accept configuration reload")
    except BaseException:
        write(remote, previous)
        write(hba, original)
        sql("SELECT pg_reload_conf()")
        raise
    print(json.dumps({"database": database, "role": role, "client": str(client),
                      "authentication": "scram-sha-256 over TLS", "superuser": False, "schemas": schemas}))


if __name__ == "__main__":
    main()
