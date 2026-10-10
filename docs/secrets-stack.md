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

Existing scripts are under `/home/ahart/secrets-stack` on hart-server:
`install.sh`, `init-openbao.sh`, `setup-auth.sh`, `go-live.sh`,
`lock-signups.sh`, `revoke-root.sh`, and `backup-secrets.sh`. This directory is
not a Git checkout. Repository ownership and integration into Operations setup
remain unfinished; these paths record the existing implementation.

The local installer now preserves an existing Vaultwarden Compose file on repeat
setup, including closed signups and other settings. If data exists but the
Compose file is missing, it refuses to recreate initial signup configuration.
Fresh-install, repeat-install and missing-configuration cases passed in isolated
filesystem fixtures. The installer was not rerun against the live stack.

`backup-secrets.timer` is active. The service last reported exit 0 at
2026-10-10 03:15:01 UTC; the next scheduled run is October 11 at 03:15 UTC.
The script takes a SQLite backup plus Vaultwarden supporting files, and a Raft
snapshot when its snapshot token exists, under `/backup/secrets`, retaining
30 days. Service success does not prove both backups exist or are restorable:
snapshot presence, off-host copies and restore drills remain unverified.

## Application integration still required

`setup-auth.sh` declares AppRoles for `hart-desktop`, `hart-laptop`, and
`hart-server`, host-specific KV paths `kv/hosts/<host>/*`, and shared paths
`kv/shared/*`. This is script evidence, not an authenticated inventory of live
roles or populated secrets. Operations delivery documentation additionally names
`host-hart-prod` and `host-hart-laptop`; reconcile actual role names and policies
before configuring consumers. No local Bao token cache was found for ahart.

Operations `setup.sh access` and `appdb` still distribute database credentials
through protected `pgpass` files. They do not yet retrieve them from OpenBao.
Keep existing consumers working until scoped authentication, secret retrieval,
renewal, restart behavior, and failure handling have been implemented and checked.
Never put secret values in `machine.env`, repository documentation or logs.

`sudo ./setup.sh machine` repairs public declaration permissions only:
`/etc/laplace` is traversable (755), and an existing `machine.env` is readable
(644). It creates no host declaration and changes no credential file's contents
or mode. On hart-server, `machine.env` was absent when checked; the user repaired
the directory mode to 755. Missing declarations and inaccessible declarations
are different states.
