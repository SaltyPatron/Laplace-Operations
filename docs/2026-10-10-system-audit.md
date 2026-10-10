# Laplace system audit — 2026-10-10

This is an ongoing audit of the invention's implementation and operating environment. Findings below are evidence, not a replacement specification or a claim that the whole system has been audited.

## Scope and authority

The user's objective is to recover a professional, dependable development environment and make progress on Laplace as a whole. Pipeline changes, cloud setup, documentation, research, implementation, and agent-history reconstruction belong to that same task. Subsequent corrections refine this scope; they do not discard earlier work.

The user identifies the Laplace monorepo as the furthest implementation. Laplace-Refactor was an attempt at a properly engineered implementation. The modular repositories were intended to enforce reuse, generics, organization and coding standards. Repository existence, agent-written descriptions, and green checks do not establish that these aims were achieved.

Evidence order: current direct instructions; original user messages and invention documents; research artifacts with their stated experimental limits; implementation and runtime observations. Agent explanations and commit messages establish what was claimed or attempted, not what the user intended. Wiki reference pages describing existing code are not automatically design authority.

Code search is unavailable: the user states the embedding service was disabled or broken. Direct repository and transcript searches are being used. No attempt to restore embeddings is authorized by that observation alone.

## Machines and operating purpose

| Machine | User-declared role | Relevant constraint |
| --- | --- | --- |
| hart-laptop | Ubuntu local development | Verify tooling and deployment portability against its actual configuration. |
| hart-desktop | Windows local development | RTX 4060 Ti; Windows behavior requires Windows evidence. |
| hart-server | Ubuntu Server development, integration and deployment staging | GTX 1080 Ti has broken cooling and is off limits. |
| hart-router | OpenWrt router | Network infrastructure, not another development host. |
| hart-cloud | Stronger AVX-512 cloud machine; production web/database environment | Shutdown schedule and actual state require separate checks. |
| hart-prod | Production hosting surface | VM running does not establish application health. |

## Documentation, research and implementation map

| Source | What has been located | What it can establish |
| --- | --- | --- |
| Laplace | `docs/INVENTION.md`, `INVENTIONS.md`, `INVENTOR_RECORD.md`, binding specs, `engine/manifest/` | Invention laws, recorded direct corrections, and existing implementation; distinguish them. |
| Laplace-Wiki | `Semantics/Claims.md`, `Sequence/Perfcaches.md`, `Reference/Types.md`, `Sequence/Conflicts.md`, research pages | Cross-repository explanations and known conflicts. The pages disagree in places; selecting one silently is not reconciliation. |
| Laplace-Refactor | `contracts/authority-stack.json`, `docs/audits/DIRECT_REQUIREMENT_EVIDENCE.md`, `requirements/product.yaml` | Locators for original requirements and explicit separation of product law, executable contracts and observed state. They do not prove the implementation satisfies those contracts. |
| Laplace-Research | Semantics, relations, learning, numerics, placement, hashing, corpus-search, recipes and prior-art work | Experimental and literature evidence. Recorded results must retain their datasets, conditions and limitations. |
| Laplace-Prototype | Storage, semantics, translation/WSD, chess, code and recipe experiments | Prior behavior and counterexamples; not proof that the modular product retained those capabilities. |
| Laplace-Native / Laplace-postgres / Laplace-Engine | Shared native code, PostgreSQL integration and executable behavior | Current call paths and storage behavior; not authority for interpreting the invention. |
| Laplace-Operations / Laplace-MCP | Deployment, checks, services and public access | Whether the intended operations actually reach a compatible installed system. |
| Other discovered roots | Laplace-Conventional, Laplace-Patreon, Laplace-Scratch, two Laplace_Hartonomous-Old roots | Present in the inventory; review and linkage remain unfinished. |

## Highway: evidence and causal history

The original Claude conversation on October 3 is preserved in local session `8200b5a3-c852-4c36-9a97-634eaad52cbd`. Its direct messages include:

- `2026-10-03T05:53:41.887Z`: the user explains POS/sense/dependency relations across sources, asking what each source says about an entity.
- `2026-10-03T05:54:14.403Z`, UUID `d441a4bd-250f-4b9e-a376-896bfc77797e`: the message names ILI, synsets, frames, POS, sense and dependency relations. The transcript also contains a duplicate event at this timestamp under UUID `8c21ba50-9704-48b0-94c8-b51cf20b394a`; these are not two independent requirements.
- `2026-10-03T07:51:45.245Z`, UUID `315b73b3-cb63-4c01-ae98-658df5ad3528`: pregenerated relations/types/kinds acting as perf-caches or flagged enums are permitted; arbitrary hardcoding and an English semantic pivot are not.

The surrounding assistant messages repeatedly reinterpret the highway first as type lists, then solely as a relation registry, then as category masks. These are documented interpretation changes, not user-approved architecture. The complete exchange must be used; quoting one of those assistant explanations as the requirement would repeat the error.

Related documentation makes distinctions that the audit must preserve:

- Wiki `Semantics/Claims.md` distinguishes flagged enum masks, identifiers without mask bits, and mappings between resources. It explicitly distinguishes relation types from POS/sense/dependency groups.
- Wiki `Reference/Types.md` describes the current type ROM and reports that only the kind bank is written; entity and occurrence carriers are not built. This is a documented implementation limit, pending fresh runtime verification.
- Refactor `requirements/product.yaml`, `LP-PERFCACHE-002`, specifies independent lifecycle and canonical parity. `LP-HIGHWAY-001` describes shared typed coordinates across languages, modalities and operations; it is broader than a POS bitmap.
- Research and Prototype include translation through witnessed ILI claims and WSD experiments. Their results distinguish standing, prevalence, POS filtering and context; a structural hash comparison alone does not establish those behaviors.

The deployment coupling has a traceable implementation history:

1. Engine commit `4b2a9f505623768339fa7c7abb75103c5bc64578` (October 1), titled as a keyed-parent repair, also added deployment of highway text contents into the database. Its code comment says the contents are needed for claims to render and pull through.
2. Engine commit `8eaa30d8350aca7747d9af7359acc04ae782f94f` (October 2) changed the sidecar from texts to compositions alongside a large decomposer change.
3. Current `src/table.c:highway_typed` returns an ID, coordinate and tier from the ROM; it does not itself construct the node's children in the ingest table. This helps explain why removing deployment's sidecar load alone may expose missing composition content. It does not justify that lifecycle.
4. Operations `deploy.sh` regenerates the highway unconditionally; Engine `cmd_deploy` reads `.nodes`, calls `load`, and calls `merge`.

Repair therefore needs to trace both source admission and consumers, preserve canonical composition and referential integrity, and provide an independently generated/installable artifact. Merely deleting the deploy call or renaming the artifact would not establish correctness. No highway implementation change has been made in this audit yet.

## Observed pipeline and verification defects

[Operations run 38069889646](https://github.com/SaltyPatron/Laplace-Operations/actions/runs/38069889646), triggered by the merge of PR #54, completed successfully on October 10.

| Observation | Evidence | Consequence |
| --- | --- | --- |
| Highway generation ran for 418.5 seconds | Runner `logs/deploy/20261010T165941Z/highway.log` | Routine deployment regenerated a persistent artifact. The comment describing this as taking seconds understates the observed cost. |
| Deploy loaded/merged highway content | Same directory, `deploy.log`: 155,362 types, 228,209 compositions, zero new entities | The separate ingest job was skipped, but deployment still executed a data-loading path. Zero new rows does not mean no load was attempted. |
| No other machine's matching record existed | `logs/verify/20261010T170700Z-build/compare.txt` | The green cross-machine check established no cross-machine comparison. |
| Local repeated decomposition matched | Same directory, `determinism.txt` | Evidence of local repeatability for two selected sources only. |
| Production checkout uses moving `main` references | `.github/workflows/laplace.yml`, production checkouts | Comments claiming the same tested revisions are not enforced by the workflow. Production was skipped in this run. |

The first implemented repair makes missing peer records and retrieval failure return exit 2 from the comparison command; mismatches remain exit 1. `verify.sh` reports incomplete evidence as incomplete, rather than as equality or a fabricated mismatch. The shell comparator also rejects a renamed local record and records for different commits. This is a bounded correction; it does not turn fingerprint comparison into deployment, integration or semantic acceptance.

## MCP and deployment ownership

Two different MCP services exist on hart-server:

- System `laplace-mcp.service`: `/usr/bin/dotnet /opt/laplace/app/mcp-runtime/Laplace.Endpoints.Mcp.dll --http`.
- User `laplace-mcp.service`: `/repos/src/Laplace-MCP/native/lpm serve 127.0.0.1 5188`.

On October 10, the native service's `tools/list` returned tools, but a `search` for `highway mask` returned `isError: true`: `physicality_t3_c` does not exist. The source had already been corrected in commit `e86961f` and merged at `d7fbc1d`; run `38019824734` built it successfully. The user service still ran an October 5 binary from the source directory. The failure was stale deployment, not an absent source fix. A successful MCP handshake is not evidence that repository search works.

An earlier probe received an empty reply and the user service restarted. Its journal reports database connections terminated by an administrator command, followed by process exit 1. That journal does not establish which operator caused the database event. A subsequent probe produced the missing-table error above.

At 17:22 UTC the native user service was repaired locally. The CI-built executable and library were installed with CMake's runtime-path relocation into `/home/ahart/.local/lib/laplace-mcp/d7fbc1d89035c1e51e59153f5ca3fa9561e7a6ab`; the user service has an `installed-runtime.conf` drop-in pointing there. The old binary was preserved. The system .NET service was not changed.

The installed pair uses Engine `7459129e79c894f2d4166b683feb4c7ee81301b0` and Native `1b9367c8055cdbd79beb1a8ba4c2d1aa322e4678`. The original install attempt copied and relocated the files but could not write the runner-owned install manifest; rerunning the generated install script with only its manifest destination redirected into the release completed successfully. The release contains `revisions.txt` and the install manifest.

Validation: `lpm check` passed; dynamic-library resolution uses the installed `liblpm.so`, not the runner copy. A candidate on port 5198 was checked before replacement and stopped afterward. The installed service on 5188 returned a successful search for `Sherlock Holmes`, with the expected ID, four containers and two claims; `highway mask` returned a valid response with no rows rather than a missing-table error. These checks demonstrate the repaired schema path only. They do not establish that repository documents are ingested, that search replaces code-search, or that the complete MCP/product contract works. Automatic delivery to this user service remains missing from CI.

## Other outstanding operational work

- Production API: earlier live inspection found `/etc/laplace` mode 700, an unreadable machine declaration for the runner, repeated restarts and no health response. The deployed revision receipt was absent. Configuration and artifact-delivery repair remains outstanding.
- Google: the working account is `thesaltypatron@gmail.com`, project `project-f5812b96-f924-41a4-94c`. Earlier audit records confirm the nightly stop at approximately 02:06 Central, a later start, and a later guest shutdown. Recheck VM state before operational decisions.
- Billing: project linkage and an open billing account were verified. Actual spend, credit remaining and expiry were not obtained; do not infer them from VM runtime or enabled billing.
- Azure: installation and cached tenant-only account were observed; usable subscription/resource access remains unverified.
- GitHub: authenticated access and PR #54 merge are verified. The tuning fixtures and focused PowerShell checks do not prove Windows execution or safe live tuning on every machine.
- Agent history: selected recent Claude exchanges and historical evidence indexes have been read. Full archive review, deduplication and correction chronology remain unfinished. No full-history audit claim is justified.

## Continuation

### Open pull requests reviewed

The October 10 inventory found three open draft PRs under SaltyPatron: Operations #57 and Engine #38/#44.

- Engine #38 is a superseded prototype. Its highway string fix has the same stable patch ID as main's `55861e9`; `src/provenance.c` and all `tools/containment-prototype` files at its head `602f56e` are byte-identical to main-history commit `99bced5`. Main subsequently merged containment work in #47 and extracted the shared walks in #52. Closing the old draft does not delete the branch or erase its recorded measurements. This does not certify the later implementation's semantic completeness.
- Engine #44 is genuinely unfinished: its own description reports incorrect sense selection, missing POS standings, recipe labels used as FrameNet strings, and 40–75-second turns. Its prerequisite #43 is merged. Passing its build does not resolve these functional defects; it must remain a tracked implementation task rather than be marked ready cosmetically.
- Operations #57's bounded verification correction has seven passing regression cases and a PowerShell parse check. Its broader audit records unfinished work; that does not make the tested correction itself unready. Land the correction without running the known defective automatic deployment chain, and continue the lifecycle repair separately within this same task.

Continue the same system-wide task after user corrections. Track fixes against their original requirement, affected consumers, actual checks and deployment state. Do not replace unfinished implementation with a completion statement, and do not require the user to re-list repositories or restart the work.
