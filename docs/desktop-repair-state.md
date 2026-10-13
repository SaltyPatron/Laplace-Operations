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
This repair subsequently requested elevation directly with Start-Process -Verb
RunAs. The first request ran the prepared serving repair, completing at
13:50:20 UTC. The second requested read/execute access for the operator on the
modular client's installed release directory; the user canceled it and it did
not run. The user objected to the unexplained UAC dialogs. No further UAC request
or alternate route for that canceled mutation is authorized without explicit
approval. No other agent was delegated this repair.

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
- IIS origin: `https://dev.hartonomous.com`. Activated and read back package
  `5cff2fc659e572e9459c5fe671aa63781cf8fe300e5107303a1f658b7bcc8392`,
  built from monorepo revision `d4bf13563b9bcffec9e01dde2772c622109985df`.
  PostgreSQL and IIS remain running. Read the live pointer before any later change.
- Operations commits: `862f99b` (desktop database/client access), `bf165fc`
  (independent platform-administrator verification). They were committed locally.
- Monorepo main and worktrees have concurrent work. Do not overwrite the
  `fix/chess-worker-selection` checkout or its uncommitted architecture/UI work.

## Resource and serving repair

The existing Windows tuning owner is `tune-pg.ps1`, called by `setup.ps1 settings`.
Its measured plan imports the machine declaration, including
`LAPLACE_PG_BUFFERS_MAX=1GB`. The cap has an existing Windows mapping rationale;
48GB installed RAM does not authorize discarding it. The monorepo also has
`scripts/pg-machine-tuning.sh` and the native/managed resource planners; reconcile
their ownership and declared allocations instead of introducing another formula.

The existing Windows plan was applied through its normal owner during the
13:50 UTC repair. All 57 declared settings now match, without pending restarts:
shared_buffers 1024MB, effective_cache_size 34205MB, work_mem 10MB, and the
existing worker, WAL, connection and observability settings. The measured 1GB
buffer cap was retained. Independent `desktop-resource-settings` acceptance
passes. Listener ownership now uses the common LAPLACE_PG_LISTEN_ADDRESSES
declaration, default '*', retaining the existing exact SSPI authentication
rules. This fixes the Tailscale interfaces missing from PostgreSQL's listeners
after reboot; TLS/SSPI checks reached all three resolved HART-DESKTOP addresses.

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

The native retained plan for consensus.band_edges now uses CURSOR_OPT_CUSTOM_PLAN
instead of CURSOR_OPT_GENERIC_PLAN, preserving its SQL and using the existing
ranked index for the actual parameters. One band/limit-five comparison in the
same read-only snapshot returned identical ordered rows: generic 6948.373ms,
custom 1.036ms. A broader run timed out and is not passing evidence. Installed
IIS home requests measured 2862.70ms and 2484.51ms; the four-band limit-five
request measured 694.77ms without a session planner override. These samples do
not explain every desktop responsiveness issue or certify every query.

See [the deployment and invention evidence](desktop-invention-verification-20261013.md)
for the full source delta, unchanged canonical trees, live representative
invariants, installation boundaries, and explicit verification limits.

## Outstanding work carried forward

- Ordinary operator access to the modular CLI remains broken: WinError 5 reading
  release `03c4df9560c2c278269deb98170d8ecb31e416c66a549540b50e76f9edda884a`
  beneath `E:/Data/Laplace/services/laplace/releases`. Elevated verification hid
  this defect; the independent ordinary-token check caught it. The owner source
  correction and scoped ACL runner are prepared, but the canceled elevation did
  not apply the live ACL change. This is not a PostgreSQL authentication failure.
- Actual browser interaction after the platform administrator grants and pgAdmin
  GUI interaction remain unobserved. Backend checks do not establish those flows.
- Whole-invention behavior, broad query parity and complete display correctness
  remain unverified. The Unicode sample in the storage-proof receipt contains
  malformed display labels even though its identity/geometry invariants pass;
  that output must not be represented as full Unicode rendering acceptance.
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
- `desktop-serving-activation-20261013.json`: completed serving activation with
  source/package/cluster identities and backup path; child receipts record
  resource, database and platform checks. Database/client checks here ran elevated.
- `desktop-postactivation-acceptance-20261013.json`: ordinary-token resource,
  platform-administrator and certificate checks passed; installed-databases failed
  on the modular release directory ACL. Overall installation remains incomplete.
- `desktop-invention-live-proof-20261013.json`: installed serving timings and
  three representative canonical-storage proofs; not whole-invention acceptance.
- `desktop-invention-source-comparison-20261013.json`,
  `desktop-installation-boundaries-20261013.json`, and
  `desktop-perfcache-comparison-20261013.json`: unchanged canonical source trees,
  installation selections and prepared-cache bytes across this deployment.

Update this state with changed facts and new evidence before handing off work.
