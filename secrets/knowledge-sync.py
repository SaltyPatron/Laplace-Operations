#!/usr/bin/env python3
"""Refresh a consumer's knowledge credential using its existing host AppRole."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import tempfile
import urllib.request


def atomic(path, text, mode, uid, gid):
    if path.is_symlink():
        raise ValueError("Refusing to replace a symbolic-link configuration file")
    fd, temporary = tempfile.mkstemp(prefix=".knowledge-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def assignments(path, values):
    stat = path.stat()
    lines = [line for line in path.read_text().splitlines() if line.partition("=")[0] not in values]
    lines.extend(key + "=" + shlex.quote(str(value)) for key, value in values.items())
    atomic(path, "\n".join(lines) + "\n", stat.st_mode & 0o777, stat.st_uid, stat.st_gid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--machine-file", type=Path, required=True)
    parser.add_argument("--lock", type=Path, default=Path("/run/lock/laplace/host-resource.lock"))
    parser.add_argument("--bao-address", required=True)
    parser.add_argument("--select", action="store_true", help="Select the credential's knowledge target and restart the API")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", args.host) or not args.bao_address.startswith("https://"):
        raise ValueError("Expected a declared host and HTTPS Bao address")
    if args.credentials.stat().st_mode & 0o077:
        raise ValueError("AppRole credentials must be private to their owner")
    lock = args.lock.open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    token = None

    def request(path, payload=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["X-Vault-Token"] = token
        data = json.dumps(payload).encode() if payload is not None else None
        with urllib.request.urlopen(urllib.request.Request(args.bao_address.rstrip("/") + "/v1/" + path,
                data=data, headers=headers), timeout=20) as response:
            body = response.read(1024 * 1024)
            return json.loads(body) if body else None

    try:
        token = request("auth/approle/login", json.loads(args.credentials.read_text()))["auth"]["client_token"]
        record = request("kv/data/hosts/" + args.host + "/knowledge")["data"]["data"]
        host, database, role = (record[name] for name in ("database_host", "database", "role"))
        if not all(isinstance(v, str) and re.fullmatch(r"[a-zA-Z0-9._-]+", v) for v in (host, database, role)):
            raise ValueError("Invalid knowledge selection")
        port = int(record["port"])
        if not 1 <= port <= 65535 or not re.fullmatch(r"[0-9a-f]{64}", record["password"]):
            raise ValueError("Invalid knowledge credential")
        account = pwd.getpwnam(args.user)
        pgpass = Path(account.pw_dir) / ".pgpass"
        env = dict(os.environ, PGPASSWORD=record["password"], PGSSLMODE="require", PGCONNECT_TIMEOUT="10")
        check = subprocess.run(["psql", "-X", "-w", "-h", host, "-p", str(port), "-U", role, "-d", database,
            "-Atqc", "SELECT current_user, encode(laplace.perfcache_receipt(), 'hex')"], env=env,
            text=True, capture_output=True, timeout=20)
        if check.returncode or not check.stdout.startswith(role + "|"):
            raise ValueError("Knowledge database authentication/native receipt check failed: " + check.stderr.strip())
        if args.select and (not args.machine_file.is_file() or not (args.prefix / "app/laplace-api.env").is_file()):
            raise ValueError("Existing machine declaration and application environment are required")
        prefix = f"{host}:{port}:{database}:{role}:"
        previous = pgpass.read_text().splitlines() if pgpass.exists() else []
        lines = [line for line in previous if not line.startswith(prefix)]
        lines.append(prefix + record["password"])
        atomic(pgpass, "\n".join(lines) + "\n", 0o600, account.pw_uid, account.pw_gid)
        if args.select:
            assignments(args.machine_file, {"LAPLACE_PGHOST": host, "LAPLACE_PGPORT": port,
                "LAPLACE_DBNAME": database, "LAPLACE_KNOWLEDGE_ROLE": role, "LAPLACE_DB_SSLMODE": "Require"})
            assignments(args.prefix / "app/laplace-api.env", {"LAPLACE_DB":
                f"Host={host};Port={port};Username={role};Database={database};SSL Mode=Require"})
            subprocess.run(["systemctl", "restart", "laplace-api"], check=True, timeout=30)
        print(json.dumps({"host": args.host, "knowledge_host": host, "database": database, "role": role,
            "authenticated": True, "native_receipt": check.stdout.strip().split("|", 1)[1],
            "selection_updated": args.select}))
    finally:
        if token:
            request("auth/token/revoke-self", {})


if __name__ == "__main__":
    main()
