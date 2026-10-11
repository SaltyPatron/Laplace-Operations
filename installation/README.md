# Existing host repair

From the updated Operations checkout on hart-server:

```sh
./setup.sh repair --check
sudo ./setup.sh repair
```

`hart-server.json` declares this installation's observed paths and services. Another installation uses
`--installation /absolute/path/to/installation.json`. Preflight rejects the wrong host, missing mounts,
unavailable services and conflicting existing machine settings before changing configuration. It does not
create volumes or build mounts. Existing additional settings remain intact.

Repair acquires the deployment/ingestion host lock, installs the public `/etc/laplace/machine.env`, checks the
latest production application backup on the backup landing volume, restores it into a new private database,
reads its application tables, and removes that scratch database. It repairs the existing secrets backup job,
runs a checked backup, extracts the backed-up Vaultwarden SQLite database and performs an integrity check.
It does not stop serving databases, restart application services, change runtime identities or modify source
checkouts. Sudo is used for this installation operation; ordinary deployment and verification remain unprivileged.

Every attempted repair after preflight saves a public, secret-free receipt under
`/var/lib/laplace/installation/receipts`. A failure returns nonzero and restores the previous machine declaration.
The secrets backup job may already have been repaired and new archives retained when a later check fails;
rerunning repair repeats its checks. A failed restore still removes its own newly created scratch database.

This proves landed database restoration and extracted SQLite integrity. It does not establish application
behavior on the restored database, a complete Vaultwarden recovery, OpenBao unseal/recovery, or runner/runtime
identity isolation. Those remain separate acceptance requirements. The database restore uses PostgreSQL's
[documented transactional restore options](https://www.postgresql.org/docs/18/app-pgrestore.html).
