# Delivery: the progression, the hosts, and what each stage proves

The inventor's progression (2026-10-10): dev → BAT → QA → load → staging → client prod → prod → BCP. This is how it
maps onto the machines Laplace has, what each stage proves before the next may start, and which mechanism of GitHub
Actions, Compute Engine and PostgreSQL carries it. Standard practice is cited where it is followed and where it is
deliberately not. Nothing here is a gate behind a click: promotion is by evidence recorded in the run, and a stage that
has not produced its evidence does not promote. One cancel never solves anything; the stage that failed says what it
found.

## The stages and the hosts

| stage | host | what runs | what it proves | evidence |
|---|---|---|---|---|
| dev | HART-DESKTOP (Windows + WSL, 24 cores, 48 GB), the laptop | the forward program, firmware, recipes against a dev database; `pwsh -File tune-pg.ps1 -Plan`, `./tune-pg.sh --plan` | the change works on the machine that made it | the branch, its PR |
| BAT | GitHub-hosted + hart-server (staging runner) | PR checks: ci-contract, unit tests, `validate-pipeline.py`; on merge, `deliver`: externals, build, install, migrate, publish on hart-server | it builds on another machine, the schema migrates in place, the API answers | the `deliver` job; `fingerprint.sh` compared with HART-DESKTOP's record for the same commits (verify.sh build) |
| QA | hart-server | acceptance reads against the staging database: the roadmap's reads (capital(France), fire/ice, dog vs chien), `verify.sh reads`, the forward program's regress baselines | the knowledge answers as invented, not as a lookup | the `reads`/`checks` jobs' summaries, kept as artifacts |
| load | hart-cloud (AVX-512, started for the job) | `benchmark-evidence.yml`: core-single, dag, streams, scale, moby; serving p50–p99 | throughput and latency against the last record; a regression fails promotion | the benchmark artifacts beside the previous record |
| staging | hart-cloud | `production-build`: the same revision built, installed and migrated on the knowledge host, the API + SPA staged and bundled | the artifact that will run is built once on the hardware it will run on | the bundle `laplace-site-<sha>` |
| client prod | hart-prod, a second hostname | the bundle published to a client/preview site (a tenant of the application database) reading the same knowledge | a real client path end to end before the public one changes | the deployment record and its URL |
| prod | hart-prod | `production`: receive, publish, restart, smoke, behind the Cloudflare tunnel | the public API, MCP and site answer | the deployment record (environment `production`, its URL), the smoke's reads |
| BCP | hart-server (the landing), hart-cloud and hart-prod (the senders) | nightly `pg_dump -Fc`, proven readable, shipped write-only to the landing; a restore drill into a scratch database | the knowledge and the accounts survive the loss of a host; a host is rebuilt from `setup.sh` and the declarations alone | the landing's listing, the drill's log |

The machines are declarations (`setup.sh`, `/etc/laplace/machine.env`, `data.tsv`), never copies of one another; production is
built from declarations and the publishers' origins (the inventor, 2026-10-09). hart-server is the inventor's "it works on
another machine"; hart-cloud is compute and the knowledge database, paid by the minute; hart-prod is the always-on hosting
host with the application database (accounts, billing, permissions: not Laplace-encoded).

## What GitHub Actions provides, and how it is used

**One slot in a queue, per host.** A concurrency group holds one running and at most one pending job; a newer pending
job replaces the older one, and ordering within a group is not guaranteed
([control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)).
So the groups are per job and per host (`laplace-site-hart-server`, `laplace-site-knowledge`, `laplace-site-hart-prod`),
never per run: a run waiting for one host does not hold the others (Laplace #1757, #1762). Group names are unique across
workflows, as the documentation requires, because a benchmark and a delivery must not displace each other.

**Deployments are recorded, not approved.** A job that names an `environment` creates a deployment with a URL and a status,
readable by the API and as webhooks
([deployment environments](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments),
[manage environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)).
Protection rules (required reviewers, wait timers, deployment branches) exist and are not used: a required reviewer held
the staging group for hours on 2026-10-09 and the knowledge host idled and stopped under a job waiting for a click
(run 38023100147). Environments are free on public repositories; the monorepo is public, so `staging` and `production`
environments give the deployment history and URLs for nothing. Environment secrets are available only to the job that
names the environment, which is where production's tokens belong once they leave the hosts' files.

**Build once, promote the artifact.** The knowledge host builds the bundle and uploads it under the revision's name; the
hosting host downloads that same bundle. Reusable workflows (`workflow_call`) are how one delivery body serves several
targets, with the caveat that the calling job cannot set the environment, the called one does
([reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)). The next refactor of
`laplace.yml` makes the deliver/build/publish body one reusable workflow called with `target: staging|knowledge|production`.

**Runners.** GitHub recommends ephemeral runners for autoscaling and advises against autoscaling persistent ones; just-in-time
runner configurations come from the REST API
([self-hosted runners API](https://docs.github.com/en/rest/actions/self-hosted-runners),
[Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)). Laplace's
hosts are fixed machines, not a pool, so each keeps one persistent runner per repository (`agents.sh`), with the unit
surviving a job's out-of-memory kill (`OOMPolicy=continue`) and restarting on failure; the hosts' own clean-up is each
job's checkout. Ephemeral registration is the step to take if a second knowledge host ever joins.

**A host started for a job.** The knowledge host is started by the run through workload identity federation (a short-lived
token, no stored key), held by the run's lease in the instance's metadata until its build job has run, and stops itself
after `LAPLACE_IDLE_STOP_MINUTES` of nothing running (`setup.sh idlestop`). The nightly resource policy at 02:00 Central is
the backstop. This is the trial's money: the host runs when a delivery or a benchmark needs it.

## What PostgreSQL provides, and how it is used

**Settings follow the machine.** `tune-pg.sh` and `tune-pg.ps1` derive every setting from the host's memory, cores, threads and
volumes under one rule set and one memory equation (README: the server's settings), and refuse to tune a server from a
client. PostgreSQL's guidance is the bound: 25% of memory for `shared_buffers` and no more than 40%; `work_mem` is spent by
every sort and hash of every backend at once; `maintenance_work_mem` is taken by every autovacuum worker unless
`autovacuum_work_mem` bounds it
([resource consumption](https://www.postgresql.org/docs/18/runtime-config-resource.html)).

**Backups.** Today: a nightly logical dump per database, proven readable, shipped to a write-only landing with retention
on both sides (`setup.sh backup`, `setup.sh landing`). A logical dump restores to the moment it was taken and nothing
later. Point-in-time recovery needs continuous WAL archiving on top of base backups
([continuous archiving](https://www.postgresql.org/docs/18/continuous-archiving.html)); pgBackRest does full, differential
and incremental backups with WAL archiving, retention, and `restore --type=time` to a timestamp
([pgBackRest user guide](https://pgbackrest.org/user-guide.html)). That is the step for the application database (accounts
and billing cannot lose a day) once it leaves `wal_level = minimal`; the knowledge database is rebuilt from its origins
and its recipes, so its dump is a convenience, not its recovery. A restore drill into a scratch database on another host
is what proves either; it is an operation to run on a schedule, and its log is the evidence.

## What is still to build

- QA as a job: the acceptance reads against the staging database after `deliver`, recorded; promotion requires them.
- Load as a job: the benchmark evidence compared with the last record; a regression stops promotion.
- Client prod: a second hostname on hart-prod for a tenant, published from the same bundle before the public site.
- Environments `staging` and `production` on the monorepo's jobs for the deployment records and URLs; no protection rules.
- One reusable delivery body called per target; the serving-latency profile (p50–p99) in the load stage.
- pgBackRest for the application database; the scheduled restore drill.
- Secrets to the hosts from the existing OpenBao deployment at deploy time. Reconcile actual AppRole names and policies before wiring consumers; see [the observed secrets stack and integration gaps](secrets-stack.md).
