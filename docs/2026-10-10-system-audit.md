# Laplace system audit — 2026-10-10

This is an ongoing infrastructure and deployment audit. The user explicitly clarified that the coding agent is not being asked to prove the invention. Findings below are evidence, not a replacement specification or a claim that the whole system has been audited.

## Latest operational observations — approximately 18:50 UTC

- Operations #64 merged at `d6286e3` after hosted CI 38076782084 passed. Push run 38076898323 passed staging deployment, readback and required reads; ingestion and production were skipped. Stack maintenance now lives under `secrets/`. Local root installation of the updated secrets backup script has not yet been verified.
- Operations #65 merged at `42b5e8e` after CI 38077156900 passed. Candidate source bundle `aac8d85` was deployed on hart-prod: `setup.sh secrets-client` authenticated the Bao appdb password against PostgreSQL, refreshed four existing consumers, and installed a 15-minute refresh timer. The systemd refresh returned status 0. A fresh `psql` connection as the runner using its password file returned `laplace|laplace-app`; its credential file is runner-owned mode600. Canonical password and AppRole files are root-owned mode600. API health is HTTP200, service active, NRestarts=0. This does not migrate knowledge DB credentials or shared OAuth/payment secrets.
- Authenticated Bao inventory confirms roles `hart-desktop`, `hart-laptop`, `hart-prod`, `hart-server`; no `hart-cloud` role returned. The `host-` prefix belongs to policies, not role names. A real Raft snapshot was downloaded into protected build scratch; both archive payload checksums passed. Decryption and restored service were not tested.
- Cloudflare API confirms unproxied `openbao` and `vault` CNAMEs to `hart-server.hartonomous.com`, whose A record is `192.168.1.2`. Proxied `api` and `mcp` records target the production tunnel; both ingress rules target hart-prod port8080. No Cloudflare configuration was changed. Certificate renewal remains unverified.
- Public API `/health` returns JSON200. Public MCP GET `/` and `/mcp` return HTML200; MCP initialize POST `/mcp` returns405. Live hart-prod nginx only proxies `/` to the API on5187; it does not have the current source template's MCP route. The host setup intentionally omits local MCP when the knowledge DB is remote. This is an unresolved deployment/route defect, not a healthy MCP endpoint.
- VM query: hart-cloud TERMINATED; hart-prod RUNNING. Actual billing spend/trial balance remain unknown. No cloud VM was started for these checks.
- The user repaired `/etc/laplace` mode755 on hart-server; its `machine.env` is absent, not an unreadable unknown override. Setup permission repair merged in Operations #63 and Laplace #1770.
- Archive inventory: 3144 session-shaped JSONL files, 2,236,510,861 bytes, 823,838 records, 457,633 user/assistant events, 141 duplicate-file groups, 33,737 exact duplicate message events, five parse errors and no read errors. Parsed timestamps span December 29, 2025 through October 9, 2026 for this candidate set. This is structural inventory, not semantic review or complete nineteen-month coverage. Protected details remain outside Git.

Earlier observations below retain their original context; the dated updates above and below supersede their unresolved status where explicitly stated.

## Scope and authority

The active acceptance criteria are operational: correct dependencies and sequence, prepared artifacts, migrations before service activation, installed-version evidence, failure propagation, recovery and declared host roles. Design documents constrain these changes; research or semantic benchmarks are not substitutes for deployment acceptance.

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

GPU scheduling correction: the Conventional runner `hart-server-Laplace-Conventional`
(GitHub runner 22) was online and idle but advertised `gpu`, `pascal`, and `1080ti`,
contrary to the user's damaged-GPU restriction. Removed those custom labels through
the GitHub runner API; retained its CPU-capable labels. The registration default now
omits GPU labels. No GPU probe or workload was executed. Registration defaults do
not overwrite an explicit machine override; root-owned machine configuration still
requires inspection where access is unavailable.

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

## Engineering and operations research — initial evidence, October 10

The user's request covers the whole engineering and operating system. Research must inform concrete corrections across requirements, repository boundaries, environments, builds, tests, artifact generation, ingestion, migrations, deployment, recovery, cloud lifecycle, costs, and continuity. A source list is not completion. External guidance does not define Laplace semantics or override the inventor's requirements. This section records preliminary findings; full-paper methodological review and implementation remain unfinished.

### Evidence and its limits

| Source | Evidence type and relevant finding | Limit |
| --- | --- | --- |
| [Soares et al., Effects of CI](https://arxiv.org/html/2103.05451v3) | Systematic review: 101 empirical studies selected from 479 candidates across six digital libraries; reports benefits and technical/process challenges. | Introduction, selected results/discussion and threats to validity inspected. It is an interpretive synthesis, not a meta-analysis; study definitions and contexts vary. Publication, selection and interpretation biases remain. This does not establish that any particular Laplace check is useful. |
| [Shahin, Babar and Zhu, CI/CD systematic review](https://arxiv.org/abs/1703.07019) | Review of 69 selected papers covering 2004–June 2016; identifies testing cost, transparency, design, domain and infrastructure as adoption factors. | Historical evidence, not current tool documentation or a universal pipeline prescription. Reviews may overlap in included studies; do not count them as independent experiments. |
| [NIST SSDF 1.1](https://csrc.nist.gov/pubs/sp/800/218/final) and [practice text](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-218.pdf) | Published security-development recommendations; PS.3.1 addresses retaining release files and supporting integrity/provenance information. | Security framework, not evidence that compliance proves product correctness or a required certification for Laplace. |
| [Microsoft operational excellence](https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/principles) | Institutional guidance connects ownership, documented operations, observability, repeatable deployment and recovery; recommends infrastructure layers aligned with lifecycle. | Recommendations require adaptation to this initial setup and hardware. Multiple Microsoft pages are not independent empirical studies. |
| [GitLab deployment safety](https://docs.gitlab.com/ci/environments/deployment_safety/) | Documents serialization of deployments and prevention of outdated deployment jobs. | Establishes platform mechanisms and concrete failure modes; does not require migrating from GitHub. |
| [GitHub deployment environments](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments) | Documents target-specific protections, secrets and deployment history. | An environment label does not provision isolation or establish service health. Approval features are optional mechanisms, not a reason to add user approval gates. |
| [DORA deployment automation](https://dora.dev/capabilities/deployment-automation/) | Guidance separates deployable packages, deployment scripts and environment configuration, and recommends exercising the deployment process before production. | One research programme; its multiple pages are not multiple independent authorities. |
| [Twelve-Factor build/release/run](https://12factor.net/build-release-run) | Practitioner methodology distinguishes executable construction, configuration and execution. | Useful separation of responsibilities; not a specification for Laplace's native engine or canonical data. |

### Application to the observed system

The following are engineering recommendations derived from the observed failures and user requirements, not claims that the sources prescribe Laplace's architecture.

| Area | Required investigation or correction | Evidence needed before calling it complete |
| --- | --- | --- |
| Requirements and history | Link behavior to original invention requirements and direct corrections; reconcile research and implementations across repositories. | Traceable requirement, implementation and counterexample records; explicit gaps in archive coverage. |
| Environments | Preserve laptop/desktop development, server staging and cloud production roles. Define credentials, configuration, service placement and database boundaries explicitly. Keep the server's damaged GPU off limits. | Installed state and deployment rehearsal on declared targets; Windows evidence for Windows claims. A host name alone proves nothing. |
| Build and release | Resolve all repository inputs to exact revisions; retain compatible artifacts and their dependencies. Promotion must identify the artifact tested. | Artifact digest, source revisions, toolchain/CPU target, deployment record and installed readback. Platform-specific binaries may differ; do not require one binary across incompatible targets. |
| Highway and ingestion | Implement the user's independent highway generation lifecycle while tracing consumers and canonical content dependencies. | Independent generation and installation; compatibility checks; explicit admission operations; tests showing ordinary deployment does not silently regenerate or ingest. |
| Tests | State each check's requirement, fixture, expected outcome and scope. Distinguish repeatability, portability, integration, deployment and semantic acceptance. | Actual assertions and failure cases. Missing peer evidence remains incomplete. Identical wrong results do not establish semantics. |
| Database changes | Assign each existing migration to its actual database and service; ship the exact scripts with the compatible release. | Migration history on the target, startup acceptance and recovery evidence. Reverting binaries alone does not reverse data changes. |
| Deployment workflow | Reuse deployment mechanics across staging and production; serialize changes to each target; prevent stale jobs overwriting newer releases. | Failure and retry behavior, exact deployed versions and endpoint checks. Audit locks across repositories as well as within a workflow. |
| Runtime and recovery | Verify API/MCP operations, restart behavior, dependencies, backups and restoration. Record manual repairs in the durable deployment mechanism. | Functional requests, observed errors, restore verification and bounded recovery behavior; process-active status is insufficient. |
| Cloud lifecycle and costs | Reconcile scheduled shutdown, job leases, starts and actual billing. Separate service availability expectations from build scheduling. | Timestamped cloud/guest events and billing observations. Current spend and trial balance remain unknown. |
| Agent continuity | Maintain one evidence-backed work record across corrections and interruptions. | Completed fixes, deployed state, failed checks and remaining work clearly separated; no invented completion or repeated requests to restate scope. |

These recommendations add neither a Kubernetes migration nor new approval bureaucracy. Choice of tooling, number of environments, rollout strategy and test cost must follow the actual workload. The immediate known defects remain the deployment/data coupling, incomplete release identity, missing service delivery and misleading verification already documented above.

### Applied finding: preserve the staging source revisions

The Operations workflow now records the three dependency commits after staging checkout and passes those job outputs into production checkout. A production preflight rejects missing or malformed commits rather than allowing checkout to fall back to a default branch. This resolves the independently moving dependency branches within a run. It does not promote an immutable binary: production still builds for its own CPU target, and generated resource versions and installed artifact digests require further work.

Local validation parsed the workflow YAML and executed its actual capture/preflight scripts against three temporary Git repositories. Valid commits passed; empty, branch-name, short and nonhex values failed. Advancing the Engine fixture branch and checking out the captured commit recovered the original staging revision. No production deployment was performed by this validation.

### Additional workflow coordination finding

Operations uses workflow group `hart-server-laplace` and deployment/ingestion file locks. The monorepo uses `laplace-site-hart-server`, `laplace-site-knowledge` and `laplace-site-hart-prod`; inspected `site.sh` uses the lock directory for restart triggers but has no corresponding deployment `flock`. Those mechanisms do not establish coordination between the repositories. This is a source-level finding, not an observed collision. Before introducing a common lock, trace shared binaries, PostgreSQL extension/schema changes and the full duration of ingestion so a partial lock does not leave the conflicting operation exposed.

The research does not support treating additional checks as automatic improvement. Soares et al. report contradictory findings for PR lifetime and confidence, with differences in how CI adoption is measured. For Laplace, evaluate checks by the defects they detect, their duration, and whether they verify the declared behavior. Microsoft's [deployment guidance](https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/safe-deployments) separately distinguishes contract compatibility from behavioral correctness and highlights the complexity of stateful rollback. These support evaluating the existing checks individually; they do not supply Laplace's semantic acceptance criteria.

## Follow-up — 2026-10-10 18:00 UTC and later

- Monorepo #1768 merged as `35a7bda40290cdf953e6ef58d881205b443dfa5d` after full CI policy run 38073878207 passed. Hidden receipts are retained, app/browser migrations are packaged and run before hosting publication, caches are staged before publication, unreadable declarations fail, and the cloud lease waits for hosting. Merged with `[skip ci]`; a full deployment is not claimed.
- The existing hart-prod API was repaired using its declared database configuration and nine existing application migrations, after retaining a database dump. `/health`, `/health/live`, `/openapi/v1.json` and `/v1/models` returned 200. Knowledge readiness timed out while hart-cloud was stopped. Installed source revision remains unknown.
- hart-prod has no system MCP unit. `site-host.sh` deliberately omits that unit on hosts using a remote knowledge database. Do not describe the absent unit as a crashed service or blindly install it. Public MCP routing and the knowledge-host endpoint still need verification.
- Engine #54 separates `.nodes` admission from deployment and adds a read-only highway fingerprint. Local clean icx build and six admission/artifact checks passed. Actual deployment into a newly created isolated database left zero entity rows with the real highway present; that test database was removed. The serving database was not loaded. PR CI and coordinated Operations rollout are tracked separately.
- Operations scripts now consume prepared artifacts. Six shell boundary cases passed, including missing artifacts before an explicit drop; seven existing comparison regressions passed. Fingerprints read installed artifacts instead of old generation logs. Generation input provenance is unknown until a receipt binds the artifact to its sources. Windows execution and automated artifact promotion remain unverified.

### Deployment gates and extension CI — 18:12 UTC follow-up

Engine #54 and Operations #60 are merged (bde37b9 and 92af13a), with no automatic deployment run. The original clean main checkouts of Engine, Operations and Laplace were fast-forwarded to the merged fixes; local source files no longer retain the older generation path or GPU runner defaults. This does not update installed services by itself.

Postgres #16 qualifies its candidate in a private package directory and temporary database instead of replacing shared extension files during PR checks. Local clean icx build, candidate-function module bindings, actual extension execution and cleanup passed; shared library/control/SQL hashes remained unchanged. GitHub run 38074637704 also passed. PostgreSQL 18's documented extension search paths support the isolated package selection.

Operations deployment checks now read extension version/tables and compare the Engine's existing tier-0/highway fingerprints with PostgreSQL's. They capture observed binary/artifact hashes without claiming missing provenance. Live readback on hart-server passed using the freshly built candidate Engine against extension 1.12; seven negative/positive boundary cases and three workflow cases (17 assertions) passed. Production depends on successful staging reads as well as deployment/readback. Cross-machine build qualification remains explicitly callable and still reports absent peers as incomplete; it is not the infrastructure gate. These changes do not validate invention semantics or replace pending full deployment/recovery rehearsal.

Linux Operations deployment and direct installation now hold an exclusive host-resource lock; ingestion holds it shared for its complete lifetime. The lock is never unlinked, and nested installs reuse descriptor 8. Background WAL samplers close their copy so they cannot retain the lock after ingestion ends. Four actual flock contention/lifetime cases passed. The monorepo site entry point is being updated to the same file/protocol with four passing contention cases. Legacy entry points and Windows host locking are not yet covered by this result.

### Completed staging rehearsal — 2026-10-10 18:19 UTC

Run [38075199422](https://github.com/SaltyPatron/Laplace-Operations/actions/runs/38075199422) deployed main `f639a786c5da1021cec5404008572d90ac7b4f2d` to hart-server with production/drop/reseed explicitly false. Deployment and infrastructure readback passed; ingestion and every production job were skipped. The deployment log contains `highway-fingerprint`, not generation or sidecar admission. Tier0/highway/layout/keys hashes match the pre-run readback.

The required CLI reads passed. The optional `fills` diagnostic spent 60 seconds and timed out; the old script explicitly ignored that result. It is being removed from ordinary deployment reads. This run is evidence of modular staging delivery and required command execution, not successful translation semantics (the translation output said no concept was attested for the sample), not full monorepo deployment and not production qualification.

At approximately 18:21 UTC, a fresh `laplace-app` dump on hart-prod restored into an isolated database with all 17 tables and nine migration journal records. The temporary database and protected dump were removed after verification. This checks local logical restoration, not off-host backup delivery or disaster recovery. The API remained active with NRestarts=0 and health 200; the backup timer was active with next run October 11 03:32 UTC.
