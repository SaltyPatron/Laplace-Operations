# Laplace-Operations

The machine Laplace runs on, and Laplace on it, from nothing: one environment file, four scripts, and the agents. The
code is in Laplace-Native, Laplace-postgres and Laplace-Engine, side by side under one source root; this repository
holds what installs, sets up, deploys, repairs and runs them (Operations in the Wiki).

```sh
git clone https://github.com/SaltyPatron/Laplace-Operations /repos/src/Laplace-Operations
cd /repos/src/Laplace-Operations
sudo ./setup.sh           # the machine: volumes, packages, rights, kernel, dependencies, cluster, settings, access
./deploy.sh               # the build, the perf-caches, the database with its schema and extension
./ingest.sh               # the sources, in recipes/order, into that database
sudo ./agents.sh          # the repositories' agents on this machine
```

`laplace.env` is the one definition of where everything is; every script here and every build reads it, and every
value in it is `${VAR:-default}`, so another machine sets its own.

## From an empty server to loaded content

```sh
./deploy.sh                                        # the database laplace.env names
LAPLACE_CONNINFO="host=/tmp port=5432 user=laplace dbname=NAME" ./deploy.sh
```

`deploy.sh` runs, in order: the build and install, tier 0 and its flags (each made only when missing), the highway (always: its slots are frozen by the manifest), the grammars (when `$LAPLACE_GRAMMARS` is empty), `laplace deploy` (the database, its extensions and settings, the schema and its indexes, the highway's records), and `laplace status`. It loads no data. It takes a lock per database, and leaves (exit 3) while an ingest of that database runs. Each step's output is kept under `$LAPLACE_WORK/logs/deploy`. `./deploy.sh drop` first drops the database through the role (`DROP DATABASE … WITH (FORCE)`, never root; never `postgres` or an empty name), then deploys it again, empty.

```sh
./ingest.sh                                        # every source, in recipes/order
./ingest.sh open-english-wordnet verbnet           # these sources
```

`ingest.sh` holds a lock per database, builds and installs nothing, and needs `laplace`, tier 0 and the highway already deployed. Its steps are `laplace ingest`, the write-ahead log it made by table and index (read each minute with `pg_walinspect` into `wal.tsv`), `laplace status` and `laplace bench`, each kept under `$LAPLACE_WORK/logs/ingest-runs/<time>`. What is recorded is passed over by its trunk, so a run that was cut off is taken up by running it again. A source is not begun when the database's volume has not the room the source was measured to take (`room` in its `source` file); that is said.

## The machine

```sh
sudo ./setup.sh                                    # once per machine: volumes, packages, rights, kernel, dependencies, cluster, settings, access
sudo ./setup.sh settings                           # one part again, after changing its declaration
sudo LAPLACE_DROP=$LAPLACE_PGDATA ./setup.sh drop all   # the cluster emptied and made again (never part of all)
```

`setup.sh` is the one step that needs root. It is not a sequence of patches: the top of the file declares the machine as sets — the volumes Laplace keeps apart (heap, WAL, temporary files, repositories, data), the packages, the dependencies built from `$LAPLACE_SRC`, the server's settings from Operations: Database, who may connect and how (`postgres` over the socket by peer, and `laplace` by peer through the `laplace` map for the operator and the runners; `laplace` and `postgres` with scram from this host, and from `$LAPLACE_LAN` over TLS only) — and each part compares its set with the machine and makes only what is missing. Run again on a finished machine it changes nothing and reports. What it did is kept under `$LAPLACE_WORK/logs/root`; the role's password is in the operator's `~/.pgpass`. Then `./deploy.sh`.

Every name of the machine's is a variable of `laplace.env` with this installation's value as its default: the paths (`LAPLACE_PREFIX`, `LAPLACE_PG_DIR`, `LAPLACE_PGDATA`, `LAPLACE_PGWAL`, `LAPLACE_PGTEMP`), the users and groups (`LAPLACE_PGUSER`, `LAPLACE_ROLE`, `LAPLACE_GROUP`, `LAPLACE_PG_GROUP`), the service (`LAPLACE_PGSERVICE`), the volumes (`LAPLACE_VOLUMES`), the network (`LAPLACE_LAN`) and the agent. Another machine sets its own before running `setup.sh`.

### The agents

```sh
sudo ./agents.sh                                   # one GitHub Actions runner per repository of $LAPLACE_REPOS, as laplace-runner
sudo ./agents.sh status                            # each, as this machine and as GitHub see it
sudo ./agents.sh remove Laplace-Wiki               # unregister and remove one (or all)
```

`agents.sh` gives every repository its own runner on this machine, all as `$LAPLACE_AGENT_USER` (default `laplace-runner`) under `$LAPLACE_AGENT_HOME/<repo>`: its own directory, environment (`runner/.env`: its builds and work under its directory; the machine's dependencies, data and database), registration (named `<host>-<repo>`, labelled `laplace,<repo>`), and service. No runner has root or any sudo rule: `agents.sh` grants none and `setup.sh rights` removes any that names one; each has the shared group and nothing more. Registration takes a token per repository: `gh` logged in as an administrator, or `LAPLACE_AGENT_TOKEN_<REPO>`. Laplace-postgres, Laplace-Engine and Laplace-Operations check out the repositories they build beside themselves; they are private and a workflow's own token reads only its repository, so `agents.sh` puts the operator's `gh` credential (or `LAPLACE_CHECKOUT_TOKEN`) in those as the secret `LAPLACE_CHECKOUT`. Each repository's `.github/workflows/laplace.yml` is its job on its runner: Native builds with icx and gcc and runs its tests under both; postgres builds, installs into the extension directories by rename (no root: the group's right) and updates the extension in the database; Engine builds and runs its checks; Wiki builds the site; Operations runs `deploy.sh` on a push, or `deploy.sh drop` when dispatched with `drop`. `ingest.yml` runs `ingest.sh` when dispatched, with the sources to ingest as its input. The operator and the agent share `$LAPLACE_GROUP`: every shared tree is that group's, set-group-id and group-writable, so neither meets a permission.

## Build

```sh
./build.sh                # the extension and the engine, each with Laplace-Native built as part of it
./build.sh install        # also installs the extension into PostgreSQL's directories; CREATE EXTENSION laplace then makes the schema
```

The three code repositories sit side by side under one source root, `$LAPLACE_SRC`; the dependencies' sources under
`$LAPLACE_DEPSRC` (the same root, unless an agent's); build trees under `$LAPLACE_BUILD`; generated data, logs and
tier 0 under `$LAPLACE_WORK`; installed dependencies under `$LAPLACE_DEPS`; the data sets under `$LAPLACE_DATA`.

## Repair

Every script here is a declaration compared with the machine, so repair is running it again: `sudo ./setup.sh` after a
volume, package, setting or access rule went missing (or one part of it: `sudo ./setup.sh settings access`);
`./deploy.sh` after a build or a database was cut off; `./ingest.sh` after a load was; `sudo ./agents.sh` after a runner was lost, or
`sudo ./agents.sh remove REPO` and again to re-register one. What each did is under `$LAPLACE_WORK/logs`.
