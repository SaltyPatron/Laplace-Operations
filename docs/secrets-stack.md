# Existing secrets services

Observed on hart-server, 2026-10-10 at approximately 18:32 UTC. These are existing
services provisioned on October 9, not services still to be installed.

| Service | Address | Existing deployment | Observation |
| --- | --- | --- | --- |
| OpenBao | https://openbao.hartonomous.com | Native `openbao.service`, package 2.7.1, Raft data under `/hosting/openbao/data` | Active, initialized, unsealed; health endpoint HTTP 200 |
| Vaultwarden | https://vault.hartonomous.com | Docker Compose `/hosting/vaultwarden/compose.yaml`, image `vaultwarden/server:1.37.4`, data under `/hosting/vaultwarden/data` | Container healthy; HTTPS HTTP 200 |

The existing installer identifies Vaultwarden as the people's password manager
and OpenBao as the machine secret store. Do not create another secret store or
reinitialize this one as a setup repair.

The user identifies Cloudflare as the DNS setup. Queries to public resolver
1.1.1.1 returned `hart-server.hartonomous.com` and private address `192.168.1.2`
for both service names. The existing installer configures nginx with the
`*.hartonomous.com` certificate, LAN/Tailscale allow rules, and loopback upstreams
8200 (OpenBao) and 8222 (Vaultwarden). This establishes local HTTPS access;
Cloudflare account settings, certificate renewal, and remote tailnet access
have not been verified. These names are not evidence of a public tunnel.

## Setup and recovery ownership

Historical scripts are under `/home/ahart/secrets-stack` on hart-server:
`install.sh`, `init-openbao.sh`, `setup-auth.sh`, `go-live.sh`,
`lock-signups.sh`, `revoke-root.sh`, and `backup-secrets.sh`. This directory is
not a Git checkout. Maintenance of installation, signup closure, publication and
backups now belongs to Operations `secrets/`. Run `sudo ./setup.sh secrets-stack`
on hart-server to converge the existing stack. This explicit part is excluded
from `all`: other machines consume secrets, rather than host another store.
Initialization, unsealing, root-token revocation and identity creation are not
invoked by setup. The old initialization/authentication scripts are historical
bootstrap tools, not repeatable deployment steps.

The repository installer preserves an existing Vaultwarden Compose file on repeat
setup, including closed signups and other settings. If data exists but the
Compose file is missing, it refuses to recreate initial signup configuration.
Fresh-install, repeat-install and missing-configuration cases passed in isolated
filesystem fixtures. Existing OpenBao configuration, including its audit stanza,
is preserved too; existing data without configuration is refused. An installed
Bao version different from the declared version requires a separate upgrade.
The repository installer has not been rerun against the live stack.

`backup-secrets.timer` is active. The service last reported exit 0 at
2026-10-10 03:15:01 UTC; the next scheduled run is October 11 at 03:15 UTC.
The script takes a SQLite backup plus Vaultwarden supporting files, and a Raft
snapshot when its snapshot token exists, under `/backup/secrets`, retaining
30 days. Service success does not prove both backups exist or are restorable:
snapshot presence, off-host copies and restore drills remain unverified.

The repository replacement backup requires both stores: missing snapshot credentials,
failed renewal, failed snapshot retrieval, SQLite corruption, or snapshot checksum
failure returns nonzero without pruning earlier backups. It stages under the backup
volume with private permissions and publishes only after validation. The SQLite
fixture was restored and read; failure fixtures preserve earlier backups. These are
script checks, not a restore drill of the live vaults. Snapshot verification follows
OpenBao's [archive format](https://pkg.go.dev/github.com/openbao/openbao/v2@v2.7.0/internal/physical/raft/snapshot):
`meta.json`, `state.bin`, and their SHA256SUMS. It does not validate unseal keys or
prove recovery on another host. Vaultwarden attachments can change independently
of its SQLite snapshot; the backup is not an atomic snapshot of all application files.

Setup installs this replacement as `/usr/local/sbin/backup-secrets`, retaining the
existing timer. It requires mounted `/hosting` and `/backup`, existing wildcard
TLS material, and existing tool prerequisites before changing services. Nginx
publication remains explicit through `sudo bash secrets/go-live.sh`; that command
now fails if either HTTPS health check is unsuccessful.

## Application integration still required

Authenticated inventory on October 10 at approximately 18:42 UTC found AppRoles
`hart-desktop`, `hart-laptop`, `hart-prod`, and `hart-server`. Their policy names
are `host-<hostname>`; the policy name is not the AppRole name. No `hart-cloud`
role appeared. The prod record `kv/hosts/hart-prod/appdb` exists with `host`,
`port`, `database`, `role`, `password`, `cluster`, and `tailnet_address` fields.
Host policies allow their own host records and reads of shared records.
`secrets/inventory.sh` reports roles, field names and versions without values.
Hart-prod can reach the Bao HTTPS health endpoint (HTTP 200).

`sudo ./setup.sh secrets-client` retrieves the declared application DB password
using `/etc/laplace/approle.json`, verifies it against PostgreSQL, then updates the
canonical and existing operator/runner `pgpass` files. Existing knowledge DB
entries are preserved. It installs `laplace-appdb-secrets.timer` for refresh every
15 minutes and two minutes after boot. Each invocation logs in with the host
AppRole and revokes its short-lived session afterwards; no admin token is installed.
Failures leave existing password files in place. This is credential distribution,
not database password rotation: a Bao value must authenticate before publication.

To enroll an existing role, an authenticated operator runs
`bash secrets/enroll-host.sh hart-prod /protected/scratch/approle.json`, then
installs that file root-owned mode 600 at `/etc/laplace/approle.json` on hart-prod.
Enrollment refuses an existing output file; it does not replace roles or rotate
already installed credentials implicitly. `LAPLACE_BAO_APPDB_HOST`,
`LAPLACE_BAO_CREDENTIALS`, and `LAPLACE_APP_PGHOST` declare overrides where needed.

Operations `setup.sh access` and `appdb` still provision database roles and maintain
their existing protected-file behavior. `secrets-client` supplies subsequent
app credential refresh. Knowledge DB credentials and OAuth/payment/API service
secrets are not yet integrated. Windows consumers are not covered by this Bash setup.
Never put secret values in `machine.env`, repository documentation or logs.

`sudo ./setup.sh machine` repairs public declaration permissions only:
`/etc/laplace` is traversable (755), and an existing `machine.env` is readable
(644). It creates no host declaration and changes no credential file's contents
or mode. On hart-server, `machine.env` was absent when checked; the user repaired
the directory mode to 755. Missing declarations and inaccessible declarations
are different states.
