# HART-DESKTOP deployment evidence, 2026-10-13

This records what the serving repair changed and what was checked. It does not
certify the complete invention or close the installation acceptance tracker.

## Deployment scope

Previous installed source: `74586cffe011260d7479fdcd9805105f93023597`.
New installed source: `d4bf13563b9bcffec9e01dde2772c622109985df`.
New package: `5cff2fc659e572e9459c5fe671aa63781cf8fe300e5107303a1f658b7bcc8392`.

The complete source delta is 37 files, 1145 insertions and 105 deletions. It
includes earlier Windows installation/access/build repairs and declared chess
worker selection changes, as well as the query-planning correction. It must not
be described as a deployment containing only one changed line. The full patch
is `desktop-deployment-full-20261013.patch` in the evidence directory below.

The native change selects a parameter-specific retained PostgreSQL plan for the
existing consensus.band_edges SQL. Its SQL, canonical engine algorithms,
composition identities and database migrations did not change. Packaged API,
CLI and UCI copies passed the native SQL contract check (155 contracts).
The engine/core and dynamics artifacts matched their corresponding build outputs.

## Evidence and limits

All receipt names below are relative to
`E:/Data/Laplace/work/laplace-mono/operator-access`.

| Checked property | Observed result | Receipt |
| --- | --- | --- |
| Canonical source | Identical Git trees for engine, substrate SQL, migrations, INVENTION.md, INVENTIONS.md, CAPABILITIES.md and docs/specs | desktop-invention-source-comparison-20261013.json |
| Prepared state | Tier-0, highway and chess-position perfcache files have identical before/after SHA256 hashes | desktop-perfcache-comparison-20261013.json |
| Installation selection | database, chess, records and environment sections identical | desktop-installation-boundaries-20261013.json |
| Existing cluster | System identifier 7696004236835714020 retained; existing PGDATA and WAL paths retained | desktop-serving-activation-20261013.json |
| Existing tuning | All 57 declared settings match, no pending restart; existing measured 1GB buffer cap retained | desktop-serving-activation-20261013.json.resources.json |
| Query semantics | Same five ordered rows for band 1, limit 5 in one repeatable-read snapshot; generic 6948.373ms, custom 1.036ms | band-page-plan-parity-20261013T1341Z.json |
| Actual website | Home 2862.70ms and 2484.51ms; four-band limit-five request 694.77ms | desktop-invention-live-proof-20261013.json |
| Canonical storage samples | All five reported invariants pass for Laplace, numeric text and mixed Unicode; decomposition roots and perfcache identities agree | desktop-invention-live-proof-20261013.json |
| Operator acceptance | Resource, platform-administrator and certificate checks pass; ordinary modular CLI directory access fails | desktop-postactivation-acceptance-20261013.json |

The storage invariants checked bounded physicalities, Tier-0 S3 placement and ROM
agreement, ordered Merkle recomposition, and packed trajectory expansion. Three
representative inputs are not exhaustive invention conformance. The mixed
Unicode receipt also contains malformed display labels; passing identity and
geometry checks does not establish correct Unicode display rendering.

The broader query parity attempt timed out and is not passing evidence. Website
timings are individual measured requests, not a guarantee for every query or an
explanation of all machine latency. Browser sign-in/admin interaction and the
pgAdmin GUI were not visually verified.

## Elevation and unfinished work

This agent directly triggered two Windows UAC requests. The first serving repair
completed at 13:50:20 UTC. The second attempted to grant the Windows operator
read/execute access to the existing modular CLI release directory; the user
canceled it before execution. No receipt exists for that ACL repair. No further
elevation or alternate route for the canceled change is authorized without
explicit approval.

The ordinary-token check remains failed. Elevated checks alone had missed that
directory-permission defect. The source correction is prepared in the existing
Windows package owner; its presence does not mean the live ACL is fixed.

The interrupted Unicode import, previously exposed credential rotation, retired
diagnostic-file cleanup, and whole-estate acceptance also remain unresolved.
See [the continuing repair state](desktop-repair-state.md) for those obligations.
