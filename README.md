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
./tune-pg.sh                                       # the server's settings, as the role: apply the declaration, reload, check
sudo ./setup.sh settings                           # the same declaration, when a pending restart needs root
sudo LAPLACE_DROP=$LAPLACE_PGDATA ./setup.sh drop all   # the cluster emptied and made again (never part of all)
```

`setup.sh` is the one step that needs root. It is not a sequence of patches: the top of the file declares the machine as sets — the volumes Laplace keeps apart (heap, WAL, temporary files, repositories, data), the packages, the dependencies built from `$LAPLACE_SRC`, the server's settings from Operations: Database, who may connect and how (`postgres` over the socket by peer, and `laplace` by peer through the `laplace` map for the operator and the runners; `laplace` and `postgres` with scram from this host, and from `$LAPLACE_LAN` over TLS only) — and each part compares its set with the machine and makes only what is missing. Run again on a finished machine it changes nothing and reports. What it did is kept under `$LAPLACE_WORK/logs/root`; the role's password is in the operator's `~/.pgpass`. Then `./deploy.sh`.

Every name of the machine's is a variable of `laplace.env` with this installation's value as its default: the paths (`LAPLACE_PREFIX`, `LAPLACE_PG_DIR`, `LAPLACE_PGDATA`, `LAPLACE_PGWAL`, `LAPLACE_PGTEMP`), the users and groups (`LAPLACE_PGUSER`, `LAPLACE_ROLE`, `LAPLACE_GROUP`, `LAPLACE_PG_GROUP`), the service (`LAPLACE_PGSERVICE`), the volumes (`LAPLACE_VOLUMES`), the network (`LAPLACE_LAN`) and the agent. Another machine sets its own before running `setup.sh`.

### The shares

```sh
sudo ./setup.sh shares                             # the SMB shares for the development machine; not part of all
```

`shares` serves `LAPLACE_SHARES` (vault, archive, backup, inbox) to `LAPLACE_SHARE_USER` alone. It uses plain SMB 3,
smbd only (nmbd is disabled), and admits only the LAN: `hosts allow` and `interfaces` cover `LAPLACE_LAN`,
`LAPLACE_SHARE_LAN6`, and link-local on `LAPLACE_SHARE_IF`, and ufw allows 445/tcp from the same sources. It
declares the whole `smb.conf` and keeps the distribution's original as `smb.conf.orig`. A change is reloaded and
never restarted, so a copy in flight is not cut. A user without an SMB password is asked for one (`smbpasswd`); it
is never written down. HART-DESKTOP checks the shares with `setup.ps1 shares`.

### The agents

```sh
sudo ./agents.sh                                   # one GitHub Actions runner per repository of $LAPLACE_REPOS, as laplace-runner
sudo ./agents.sh status                            # each, as this machine and as GitHub see it
sudo ./agents.sh remove Laplace-Wiki               # unregister and remove one (or all)
```

`agents.sh` gives every repository its own runner on this machine, all as `$LAPLACE_AGENT_USER` (default `laplace-runner`) under `$LAPLACE_AGENT_HOME/<repo>`: its own directory, environment (`runner/.env`: its builds and work under its directory; the machine's dependencies, data and database), registration (named `<host>-<repo>`, labelled `laplace,<repo>`), and service. No runner has root or any sudo rule: `agents.sh` grants none and `setup.sh rights` removes any that names one; each has the shared group and nothing more. Registration takes a token per repository: `gh` logged in as an administrator, or `LAPLACE_AGENT_TOKEN_<REPO>`. Laplace-postgres, Laplace-Engine and Laplace-Operations check out the repositories they build beside themselves; they are private and a workflow's own token reads only its repository, so `agents.sh` puts the operator's `gh` credential (or `LAPLACE_CHECKOUT_TOKEN`) in those as the secret `LAPLACE_CHECKOUT`. Each repository's `.github/workflows/laplace.yml` is its job on its runner: Native builds with icx and gcc and runs its tests under both; postgres builds, installs into the extension directories by rename (no root: the group's right) and updates the extension in the database; Engine builds and runs its checks; Wiki builds the site; Operations runs `deploy.sh` on a push, or `deploy.sh drop` when dispatched with `drop`. `ingest.yml` runs `ingest.sh` when dispatched, with the sources to ingest as its input. The operator and the agent share `$LAPLACE_GROUP`: every shared tree is that group's, set-group-id and group-writable, so neither meets a permission.

### The deployment target: every merge to main

hart-server is the target every merge deploys to: the developer's gate for "does it work on another machine". A push to
this repository's main, and a `repository_dispatch` (`main-merged`) that Laplace-Native, Laplace-postgres and
Laplace-Engine send from their own `laplace.yml` once their CI passes on main, run `laplace.yml` here with every
repository at its main, one deployment at a time (the concurrency group `hart-server-laplace`, which `ingest.yml` shares):

| job | what |
|---|---|
| deploy | `seed-stamp.sh decide`, then `deploy.sh`, or `deploy.sh drop` when the database is reseeded |
| checks | `verify.sh build`: the build's record (`fingerprint.sh`), determinism, HART-DESKTOP's record for the same commits |
| ingest | when the policy says so: `ingest.sh` (every source of `LAPLACE_SOURCES`), then `seed-stamp.sh seeded` |
| reads | `verify.sh reads`: `laplace status`, and `text`, `hop`, `translate`, `fills` through the indexes |

Each job writes what it found to the run's summary.

**The reseed policy** (`seed-stamp.sh`). A database carries, as its comment, the stamp of the code it was seeded from: a
hash of the trees of Laplace-Native, Laplace-Engine (its source and recipes), Laplace-postgres and Operations'
floating-point contract (`toolchain/`, `math/`, `patches/`, `dependencies.tsv`). Documentation, workflows, tests and the
firmware do not count, since none of them changes what is recorded. When the stamp the code makes differs from the
database's, or the database has none, the deployment drops the database and seeds it again from empty. The data on the
target is expendable; the repository variable `LAPLACE_RESEED=never` stops automatic reseeds. A reseed that was cut
off leaves the stamp `pending`, and the next deployment with the same stamp picks the ingest up again without a drop.
By hand, in one click: `laplace.yml` with `drop` (empty, no ingest) or `reseed` (drop, then every source), or
`ingest.yml` with `reseed`.

**Does it work on another machine** (`verify.sh`, `fingerprint.sh`, `fingerprint.ps1`). Every deployment writes the
record of its build: the commits, tier 0 and its flags made afresh, the highway, and, for each source of
`LAPLACE_DETERMINISM`, the claims its recipes make, counted and hashed as a sorted set. Each source is decomposed twice,
and the two runs must agree. The record is published on the branch `fingerprints` of this repository, at
`<native>-<engine>/<machine>.txt`, and compared with every other machine's record for the same commits. On
HART-DESKTOP, `pwsh -File fingerprint.ps1`, run after `build.ps1` at the commits a deployment names, writes the
Windows record beside it, and either side reports any field that differs.

`laplace.sh`, installed as the operator's `~/.local/bin/laplace`, runs the program the last deployment built, with its
code, recipes and environment.

The root steps are `sudo ./setup.sh`. Its part `site` runs the monorepo's `deploy/linux/site-host.sh` (the API and SPA
over `laplace-mono` behind nginx). Its part `agents` runs `agents.sh`, which gives every repository of `LAPLACE_REPOS` its
runner. `agents.sh status` fails when any repository of the owner with a self-hosted workflow has no runner here, or is
missing from `LAPLACE_REPOS`. A runner carries `LAPLACE_AGENT_LABELS`, its repository's name, and the repository's own
labels from `LAPLACE_AGENT_LABELS_<repo>` (Laplace-Conventional's ask for the GTX 1080 Ti).

## Build

```sh
./build.sh                # the extension and the engine, each with Laplace-Native built as part of it
./build.sh install        # also installs the extension into PostgreSQL's directories; CREATE EXTENSION laplace then makes the schema
```

The three code repositories sit side by side under one source root, `$LAPLACE_SRC`; the dependencies' sources under
`$LAPLACE_DEPSRC` (the same root, unless an agent's); build trees under `$LAPLACE_BUILD`; generated data, logs and
tier 0 under `$LAPLACE_WORK`; installed dependencies under `$LAPLACE_DEPS`; the data sets under `$LAPLACE_DATA`.

## Windows (the development machine)

```powershell
pwsh -File setup.ps1                  # the machine: volumes, packages, rights, dependencies, cluster, settings, access, report
pwsh -File setup.ps1 deps report      # one part, or several
pwsh -File tune-pg.ps1 -Check         # the server's settings against their declaration; without -Check: apply, restart when allowed, check
```

`setup.ps1` is `setup.sh`'s counterpart: the same parts, each a declaration compared with the machine, logged under
`$LAPLACE_WORK\logs\root`; the parts that touch the service, its rights, its settings and its access need an elevated
PowerShell and refuse otherwise, so the rest runs as the developer. `laplace.env.ps1` is `laplace.env`'s: every name of
the machine's (the roots, the cluster and its log, the service and its account, the role, the network, the locks) and
what the settings' rules cannot read from the machine (what its other residents keep, the shared memory this Windows
build maps, the log's room on a shared drive), each with the measurement that set it. `tune-pg.ps1` is `tune-pg.sh`'s:
the settings derived from the machine the same way and checked by the same statement, so the Linux server and the
Windows one each get their own numbers from one set of rules.

What differs is only what Windows forces. No volume is made: `volumes` reports each root's drive and makes its
directory. The toolchain is installed by hand (Visual Studio, oneAPI, CMake, Git, uv) or by the manifest: `packages`
says what is missing and installs MSYS2's packages. There is no kernel part (huge pages stay off until the backends'
shared-memory mapping is measured to bear them). The server is a Windows service under `NT AUTHORITY\NetworkService`;
there is no socket, so every local connection is scram on loopback. `deps` reads the same `dependencies.tsv`: every row
for `windows` checked out at its commit, or downloaded, verified by SHA-256 and unpacked; then every row with a `build`
whose `proof` is missing, built and installed into its own prefix. The builds use icx under the floating-point contract
in `toolchain/determinism.tsv`: laplace-math first (`math/`), CMake builds through `-DCMAKE_TOOLCHAIN_FILE=toolchain/laplace.cmake
-DLAPLACE_MATH=<laplace-math.lib>`, PostgreSQL's Meson build through the native file `toolchain/meson-native.py msvc
<laplace-math.lib>` writes, with `patches/postgresql`, and PostGIS by `toolchain/windows/postgis.sh` in MSYS2's shell
(from the oneAPI dev shell, `MSYSTEM=MSYS MSYS2_PATH_TYPE=inherit`, `LAPLACE_MATH` set), which applies `patches/postgis`,
configures, builds and installs into that PostgreSQL. On Windows every link ends with laplace-math and then libmmd,
Intel's libm, kept for the exact operations only; no transcendental function in any installed binary comes from it.

The Windows machine is one leg of the cross-OS check: a database the Linux machine's clients reach over `$LAPLACE_LAN`
with TLS, and a client of the Linux machine's database (`LAPLACE_CONNINFO`); `report` tries both. The role has one
password across the installation, the deployment target's: `access` reads it from `LAPLACE_PEER`'s operator pgpass over
the operator's SSH key and gives it to the role here, so one pgpass line reaches both databases; the operator's pgpass
lines for other hosts are kept. HART-DESKTOP's one-time cleanup of what earlier set-ups left is
`toolchain/windows/retire.ps1`, not part of setup.

### The desktop's own parts

Three parts of `setup.ps1` declare what HART-DESKTOP is besides a Laplace host. None is part of `all`; each is named to
be run, says what it changed, changes nothing on a second run, and with `status` (`setup.ps1 backup status`; alone,
`setup.ps1 status`, all three) only reports. Their names are variables of `laplace.env.ps1`.

```powershell
pwsh -File setup.ps1 shares           # hart-server's shares answer by UNC path, with a credential
pwsh -File setup.ps1 services         # elevated: the operator may start, stop and query the GPU services
pwsh -File setup.ps1 firewall         # elevated: the inbound rules this machine's endpoints need
pwsh -File setup.ps1 backup           # the copy-off task, registered or updated; then its state
pwsh -File setup.ps1 status           # all four, reporting only
```

**shares** checks, and makes nothing: the Credential Manager entry for `LAPLACE_SHARE_HOST` (never printed), that
445/tcp answers, and that each `\\<host>\<share>` of `LAPLACE_SHARES` answers. No drive letter is mapped and the
operator's Explorer locations are left alone. A failed check says what to do: `cmdkey /add:hart-server /user:ahart
/pass` (it asks for the password), or `sudo ./setup.sh shares` on hart-server.

**services** appends one allow ACE for the operator's own SID (`LCRPWPLO`: query, start, stop, interrogate) to each
service of `LAPLACE_GPU_SERVICES`, so `chess\chess-gpu.ps1` switches the card without elevation. Already granted is
known by the SID, never by the ACE's text (Windows reorders the rights). A change prints the SDDL before and after;
`sc.exe sdset <service> "<before>"` undoes it.

**firewall** makes the inbound rules of `LAPLACE_FIREWALL` (`name=port@client;…`; today `engines=5190@192.168.1.2`, the
engine endpoint for hart-server): one named rule each, TCP, from that one client, on private networks. A missing rule
is created and one whose port, client or profile differs is corrected; a second run changes nothing.

**backup** is the copy-off of HART-DESKTOP's drives to hart-server, in `backup\`. `jobs.psd1` is the job list: each
set (D:, then C:'s `source`) with its inbox, and each job's source, destination, robocopy exclusions, manifest
destination and whether it is only hashed. The `Models-*` jobs are on hold and run only with `-Models`. `copyoff.ps1
-Set D` writes each job's SHA-256 manifest first (`hash-manifest.ps1`: compiled C#, 8 workers, rows streamed to
`.part`; `# path<TAB>size<TAB>sha256   source=ROOT`, the rows, `# total files=N bytes=B`). It then checks for room on
hart-server over SSH (what is left to copy, plus 5 GiB, or exit 3 and nothing more is copied) and copies with
`robocopy /E /COPY:DAT /DCOPY:DAT /XJ /FFT /R:2 /W:5 /MT:8 /NP /UNILOG+`. It never uses `/MIR`, `/PURGE` or `/MOV`.
The D: set also keeps the uncommitted edits in `LAPLACE_DEPSRC`'s checkouts as patches. `run.ps1` runs every set.
The part registers it as the scheduled task `LAPLACE_BACKUP_TASK`, which runs as the operator, interactive and not
elevated, with no time limit and no trigger, in a headless console. The part never changes the task while it runs.
Start it with `Start-ScheduledTask -TaskName copyoff`; logs and manifests are under `LAPLACE_BACKUP_LOGS`.

## The chess lab's conventional reference

Stockfish, fastchess, Ordo, Lc0, Lc0's networks and the opening suites are rows of `dependencies.tsv`, each pinned by
commit or by SHA-256 (a `data` row is a file the lab reads, fetched into `$LAPLACE_DATA`). fastchess conducts matches,
SPRT and the ladder; cutechess stays for the GUI (Laplace-Wiki, Sequence/Conflicts.md K1). Syzygy tables are not
provisioned here: an engine probes them as a provider, and they are not content Laplace depends on.

```sh
sudo ./setup.sh chess                 # Linux: chess/provision.sh as the operator (2 cores, niced), then the links in /usr/local/bin
chess/provision.sh report             # what is installed: each program by SHA-256, Stockfish's bench, the data rows
```

On Linux Stockfish is built with `make profile-build ARCH=$LAPLACE_STOCKFISH_ARCH` (default `x86-64-bmi2`) and
`$LAPLACE_STOCKFISH_CXX` (default `g++-12`), and is installed only when its bench prints the generation's node count
(2497913 for sf_19); Lc0 is built from its tag with the plain CUDA backend (fp32 on hart-server's GTX 1080 Ti) when
the machine has an NVIDIA GPU. On Windows `setup.ps1 deps` unpacks fastchess, Ordo and Lc0's CUDA 12 package and
fetches the data rows; Stockfish there is the monorepo's `install-stockfish.py`.

The RTX 4060 Ti on HART-DESKTOP is shared with the llama.cpp embedders code search depends on, so it has two modes,
switched explicitly and without elevation (the operator holds start, stop and query on the three services):

```powershell
pwsh -File chess\chess-gpu.ps1 status     # the services, their /health, the card's free memory, any Lc0
pwsh -File chess\chess-gpu.ps1 on         # chess-GPU mode: the embedders stopped, the card free for Lc0
pwsh -File chess\chess-gpu.ps1 off        # index mode, the default and what a reboot returns to
```

Each switch is journaled in `$LAPLACE_WORK\logs\chess-gpu.tsv` for the match generation's receipt. Lc0 is never a
service: the conductor starts it per match, only in chess-GPU mode.

## Repair

Every script here is a declaration compared with the machine, so repair is running it again: `sudo ./setup.sh` after a
volume, package or access rule went missing; `./tune-pg.sh` after a server setting drifted (`deploy.sh` runs it, and
the job fails when the live server does not match); `sudo ./setup.sh settings` when a pending restart needs root;
`./deploy.sh` after a build or a database was cut off; `./ingest.sh` after a load was; `sudo ./agents.sh` after a runner was lost, or
`sudo ./agents.sh remove REPO` and again to re-register one. What each did is under `$LAPLACE_WORK/logs`.
