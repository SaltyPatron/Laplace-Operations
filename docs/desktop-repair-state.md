# Desktop Laplace repair state

Last updated: 2026-10-13. This is continuation evidence, not a replacement for the
invention, the user's instructions, or the installation acceptance criteria.

## Objective and boundaries

Restore and verify the existing Laplace installation on HART-DESKTOP, including
the custom PostgreSQL build, isolated local substrate/application databases,
Windows operator access, Google/Microsoft platform administration, installed
clients, website/API/MCP, existing machine resource declarations and actual
serving performance. A successful connection or readiness response does not
establish that this objective is complete.

Use the monorepo's AGENTS.md, invention documents and engineering rules, this
repository's installation map, operating guide and acceptance criteria. Desktop
is development, server is staging and intentional production failover, prod is
the always-on production application/fallback host. Keep cloud off. Do not create
another PostgreSQL cluster, reset data, substitute an empty fixture, or replace
existing tuning with guessed values. The user rejected personal Bao login as a
prerequisite for operating an already enrolled installation.

The user objected to coordination with an elevated session. No such delegation
or update was authorized by this repair. Another existing task sent unsolicited
requests concerning a prepared IIS/chess update and active cross-host matches.
Those messages are not authorization to publish its package or restart services.
The current shell was observed to be non-elevated after the machine reboot.
A local SSH attempt failed host-key verification before running a command.

## Installed state and verified changes

- Machine declaration: `C:/ProgramData/Laplace/machine.env`.
- Custom PG18.6: `D:/Libraries/postgresql/18.6`; service `laplace-postgres`;
  PGDATA `E:/Data/Laplace/pgdata`; WAL `D:/Data/Laplace/pg_wal`;
  cluster system identifier `7696004236835714020`. These are live data directories.
- Local databases: `laplace-mono` (monorepo substrate), `laplace-desktop-app`
  (browser identity/accounts), and `laplace` (modular implementation).
- Human operator `ahart` uses exact Windows SSPI mapping locally and a
  non-exportable Windows-store certificate remotely. Restricted desktop runtime
  roles use SSPI; PostgreSQL administrator access is separate from platform access.
- Both observed Google and Microsoft provider accounts for the operator were
  assigned `administrator` through Laplace's audited role endpoint at 12:49 UTC.
  Exact identities are declared in `installation/hart-desktop-operator.json`.
  Grants persist in the application database and are read on each request.
  Browser interaction after the grant has not been observed.
- IIS origin: `https://dev.hartonomous.com`. Last inspected active package:
  `a9385bedcab51fb56b3f10cf6653ad3124c0c3c81b393f94220e7dd85a997c20`.
  Read the live pointer again before changing it; another task is preparing an update.
- Operations commits: `862f99b` (desktop database/client access), `bf165fc`
  (independent platform-administrator verification). They were committed locally.
- Monorepo main and worktrees have concurrent work. Do not overwrite the
  `fix/chess-worker-selection` checkout or its uncommitted architecture/UI work.

## Unresolved configuration and performance defects

The existing Windows tuning owner is `tune-pg.ps1`, called by `setup.ps1 settings`.
Its measured plan imports the machine declaration, including
`LAPLACE_PG_BUFFERS_MAX=1GB`. The cap has an existing Windows mapping rationale;
48GB installed RAM does not authorize discarding it. The monorepo also has
`scripts/pg-machine-tuning.sh` and the native/managed resource planners; reconcile
their ownership and declared allocations instead of introducing another formula.

The running cluster was observed with PostgreSQL defaults: shared_buffers 128MB,
work_mem 4MB, effective_cache_size 4GB, pg_stat_statements not preloaded and I/O
timing disabled. The existing Windows plan instead declares shared_buffers
1024MB, effective_cache_size 34205MB and work_mem 10MB on the measured machine,
along with its other worker, WAL, connection and observability settings.
The existing `desktop-installed-databases` check did not verify tuning convergence.
No tuning change or restart has yet been applied by this diagnostic pass.
Also reconcile the tuner's wildcard listener declaration with the exact
`localhost,HART-DESKTOP` operator-access declaration before applying it.

At 12:56 UTC PostgreSQL PID28556 was serving IIS PID29648 as
`laplace_desktop_db`, running `ops.band_leaders`. It used approximately one CPU
core and 600–650MB/s of process reads, while physical disk traffic and queues
were low. Its request ended after 122.076 seconds. Total CPU was 7–12%, available
RAM about33GB, with no paging pressure. These samples identify a slow Laplace
request; they do not establish the cause of every desktop responsiveness issue.

A bounded native nested-plan trace reached these paths:

1. `leaders.named` -> `ops.band_leaders` -> `consensus.band_edges`.
2. The retained generic arena plan used the score-only partition indexes,
   filtered the relation afterward and incrementally sorted ties. One band took
   4465ms in the captured trace despite requesting five entries.
3. `display.labels` -> `realize.display_label_batch` -> `render_text_batch` ->
   `constituents_closure`. The diagnostic request hit its five-second timeout
   inside closure after the arena and lexical-label stages.

Root partitioned tables entities, physicalities and consensus have `reltuples=-1`
in the inspected catalog. Determine statistics/index completeness and inspect
the actual frontier plan before choosing a native change or maintenance action.
Do not claim the entire 122 seconds is explained by the five-second trace.
Preserve the result semantics, canonical composition, batching and content IDs.

## Outstanding work carried forward

- Restore convergence through the existing installation/tuning owner and add an
  independent live acceptance check; report required restart separately.
- Correct and measure the actual leaderboard/display path on populated data,
  including output parity and repeated requests through the running website.
- Recheck the exact installed revision, browser/admin behavior and client/runtime
  boundaries after an authorized installation change.
- The Unicode import and its monitor were interrupted by the host restart at
  12:10:26 UTC. Their previous running receipt was corrected. Completion is not
  verified; do not start another ingest concurrently or claim it finished.
- An earlier rollback printed credential configuration into tool output.
  Output handling was fixed, but exposed values have not been rotated.
- A diagnostic CSV remains in a retired IIS package after tool-level deletion
  rejection. Do not bypass that rejection or conflate it with live PGDATA/WAL.
- Whole-estate installation and invention acceptance remain open in the existing
  Operations tracker. Do not replace them with these selected checks.

## Evidence

Work root: `E:/Data/Laplace/work/laplace-mono/operator-access`.

- `desktop-platform-admin-20261013.json`: audited enrollment/readback.
- `desktop-platform-access-20261013T125500Z.json`: passing independent platform
  role/provider check and anonymous denial; not a browser-session test.
- `desktop-final-20261013T114350Z.json`: earlier selected database/runtime checks,
  before reboot and before the platform-role repair; not tuning acceptance.
- `band-leaders-nested-plan-20261013.log`: bounded nested execution trace.
- `desktop-existing-tuning-drift-20261013.json`: declared/live settings. Its first
  diagnostic capture had a PowerShell variable-name collision in the plan field;
  regenerate that field before treating the document as a complete plan receipt.
- `desktop-unicode-bootstrap-20261013.json`: interrupted import state.
- `desktop-database-repair-20261013.json`: prior repairs and remaining limitations.

Update this state with changed facts and new evidence before handing off work.
