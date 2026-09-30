# Laplace-Operations

The machine Laplace runs on, and Laplace on it, from nothing: one environment file, three scripts, and the agents. The
code is in Laplace-Native, Laplace-postgres and Laplace-Engine, side by side under one source root; this repository
holds what installs, sets up, deploys, repairs and runs them (Operations in the Wiki).

```sh
git clone https://github.com/SaltyPatron/Laplace-Operations /repos/src/Laplace-Operations
cd /repos/src/Laplace-Operations
sudo ./setup.sh           # the machine: volumes, packages, kernel, dependencies, cluster, settings, access
./deploy.sh               # from an empty server to loaded, indexed and measured content
sudo ./agents.sh          # the repositories' agents on this machine
```

`laplace.env` is the one definition of where everything is; every script here and every build reads it, and every
value in it is `${VAR:-default}`, so another machine sets its own.

## From an empty server to loaded content

```sh
./deploy.sh                                        # the database laplace.env names
LAPLACE_CONNINFO="host=/tmp port=5432 user=laplace dbname=NAME" ./deploy.sh
```

`deploy.sh` runs the five steps of Deployment in order: build and install, the perf-caches (tier 0, its flags, the highway), the grammars, `laplace deploy`, `laplace ingest`, then `laplace status` and `laplace bench`. It can be run again: what is built is not rebuilt, what is recorded is passed over by its bytes, and a run that was cut off is taken up where it stopped. Each step's output is kept under `$LAPLACE_WORK/logs/deploy`, and each source's under `$LAPLACE_WORK/logs/ingest`.

A source is not begun when the database's volume has not the room the source was measured to take (`room` in its `source` file); that is said, and the run goes on to the next.

## The machine

```sh
sudo ./setup.sh                                    # once per machine: volumes, packages, kernel, dependencies, cluster, settings, access
sudo ./setup.sh settings                           # one part again, after changing its declaration
```

`setup.sh` is the one step that needs root. It is not a sequence of patches: the top of the file declares the machine as sets — the volumes Laplace keeps apart (heap, WAL, temporary files, repositories, data), the packages, the dependencies built from `$LAPLACE_SRC`, the server's settings from Operations: Database, who may connect and how (the operator over the socket; `laplace` from `$LAPLACE_LAN` with scram over TLS; nothing else) — and each part compares its set with the machine and makes only what is missing. Run again on a finished machine it changes nothing and reports. What it did is kept under `$LAPLACE_WORK/logs/root`; the role's password is in the operator's `~/.pgpass`. Then `./deploy.sh`.

Every name of the machine's is a variable of `laplace.env` with this installation's value as its default: the paths (`LAPLACE_PREFIX`, `LAPLACE_PG_DIR`, `LAPLACE_PGDATA`, `LAPLACE_PGWAL`, `LAPLACE_PGTEMP`), the users and groups (`LAPLACE_PGUSER`, `LAPLACE_ROLE`, `LAPLACE_GROUP`, `LAPLACE_PG_GROUP`), the service (`LAPLACE_PGSERVICE`), the volumes (`LAPLACE_VOLUMES`), the network (`LAPLACE_LAN`) and the agent. Another machine sets its own before running `setup.sh`.

### The agents

```sh
sudo ./agents.sh                                   # one GitHub Actions runner per repository of $LAPLACE_REPOS, as laplace-runner
sudo ./agents.sh status                            # each, as this machine and as GitHub see it
sudo ./agents.sh remove Laplace-Wiki               # unregister and remove one (or all)
```

`agents.sh` gives every repository its own runner on this machine, all as `$LAPLACE_AGENT_USER` (default `laplace-runner`) under `$LAPLACE_AGENT_HOME/<repo>`: its own directory, environment (`runner/.env`: its builds and work under its directory; the machine's dependencies, data and database), registration (named `<host>-<repo>`, labelled `laplace,<repo>`), service, and rights — the Operations runner alone may run `setup.sh` of its checkout as root and restart the server; the others have nothing beyond the shared group. Registration takes a token per repository: `gh` logged in as an administrator, or `LAPLACE_AGENT_TOKEN_<REPO>`. Laplace-postgres, Laplace-Engine and Laplace-Operations check out the repositories they build beside themselves; they are private and a workflow's own token reads only its repository, so `agents.sh` puts the operator's `gh` credential (or `LAPLACE_CHECKOUT_TOKEN`) in those as the secret `LAPLACE_CHECKOUT`. Each repository's `.github/workflows/laplace.yml` is its job on its runner: Native builds with icx and gcc and runs its tests under both; postgres builds, installs into the extension directories by rename (no root: the group's right) and updates the extension in the database; Engine builds and runs its checks; Wiki builds the site; Operations runs `setup.sh` and `deploy.sh`. The operator and the agent share `$LAPLACE_GROUP`: every shared tree is that group's, set-group-id and group-writable, so neither meets a permission.

## Build

```sh
./build.sh                # the extension and the engine, each with Laplace-Native built as part of it
./build.sh install        # also installs the extension into PostgreSQL's directories
```

The three code repositories sit side by side under one source root, `$LAPLACE_SRC`; the dependencies' sources under
`$LAPLACE_DEPSRC` (the same root, unless an agent's); build trees under `$LAPLACE_BUILD`; generated data, logs and
tier 0 under `$LAPLACE_WORK`; installed dependencies under `$LAPLACE_DEPS`; the data sets under `$LAPLACE_DATA`.

## Repair

Every script here is a declaration compared with the machine, so repair is running it again: `sudo ./setup.sh` after a
volume, package, setting or access rule went missing (or one part of it: `sudo ./setup.sh settings access`);
`./deploy.sh` after a build, a database or a load was cut off; `sudo ./agents.sh` after a runner was lost, or
`sudo ./agents.sh remove REPO` and again to re-register one. What each did is under `$LAPLACE_WORK/logs`.
