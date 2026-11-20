---
name: laplace-invention
description: Deep byte-level and operational reference for Laplace (identity, tiers, Tier-0, mantissa path carrier, 64-bit mask banks, schema, in-place reconcile, ingest VM, Forward/Model/Export, end-to-end delivery checklist). Load for any Laplace task touching layouts, schema, ingest, retrieval, synthesis, or documentation.
metadata:
  short-description: Laplace byte-level reference + end-to-end delivery checklist
---

# Laplace — Deep Reference

Core mandate, truth hierarchy (`INVENTOR_RECORD.md` + `INVENTION.md` + decided `Sequence/Conflicts.md` > `Architecture.md` > modular packages > monorepo migration debt), and the 1.0 finish line live in `Laplace-Operations/agents/AGENTS.md`. Always check documentation and code together; when agent-written code contradicts the invention, fix the code to match the invention.

## 1. Exact Byte & Bit Layouts (`Laplace-Native`)

| Structure | Layout | Source (`Laplace-Native`) |
| :--- | :--- | :--- |
| `lp_id` (16 B) | First 16 bytes of BLAKE3-256 (`uint8_t b[16]`, 32 lowercase hex chars). Zero salt, zero domain byte, zero tier/recipe/position prefix | `include/laplace/laplace.h` (`lp_id`, `lp_id_codepoint`, `lp_id_compose`) |
| Composition | Leaf = BLAKE3-128(1..4 UTF-8 bytes of codepoint). `n==1` → child itself (`compose_refs` singleton collapse). `n>=2` → BLAKE3-128($16n$ child IDs in order, repeats included); `tier = lp_tier_above` = `1 + max(child.tier)` (saturates at 255) | `src/compose.c` (`lp_ref_compose`), `laplace.h` (`lp_tier_above`) |
| `lp_tier0_record` (64 B) | `id[16]`, `int64 m[4]` (fixed point $m / 2^{53}$), `uint64 hilbert`, `uint32 rank` (DUCET), `uint32 pad` | `laplace.h`, `tier0.h`, `src/tier0.c` |
| Tier-0 shards | 1,114,112 records: `ascii` (128), `utf` (22,112), `cjk` (115,920), `ext` (975,952). Select via `LAPLACE_TIER0_PROFILE` (`ascii`, `utf`/`latin`, `cjk`/`bmp`, `ext`, `full`/`all`) or `@profile` suffix; IDs and coords are identical across profiles | `tier0.h`, `src/tier0_map.c` |
| Flags (32 B/cp) | 256-bit Unicode property record per codepoint + `.layout`; shards `<stem>.flags.<shard>.bin` | `laplace.h` (`lp_flags`), `src/flags.c` |
| Highway ROM | Shards `core` (banks), `wordnet` (ILI), `frames` (roles); `LAPLACE_HIGHWAY_PROFILE` (`core`, `wordnet`, `frames`, `lexical`/`full`). Generated from `manifest/` + `tier0.bin` with no raw corpora needed on disk | `highway.h`, `src/highway.c` |
| Centroid & Wall | Exact `__int128` sum divided by $n$ truncating toward zero; wall test $\sum_{d=0}^3 m_d^2 \le 2^{106}$ (`lp_coord_inside`); Tier-0 shell nudged strictly inside | `src/coord.c`, `src/tier0.c` |
| Hilbert key | 4D 16-bit Skilling + BMI2 `pdep`; SQL stores `h ^ 0x8000000000000000` so signed `bigint` sort = unsigned Hilbert order | `laplace.h` (`lp_hilbert4`, `lp_hilbert_key`), `src/isa/hilbert_bmi2.c` |
| Path vertex X/Y/Z | IEEE-754 binary64 with biased exponent 1021 (values in `[0.25, 0.5)`): low `43 + 43 + 42 = 128` mantissa bits carry child `lp_id`; upper `9 + 9 + 10 = 28` spare bits carry `4-bit tag + 24-bit payload` (e.g. `LP_SPARE_SCORE`: score $\times 2^{24}$) | `laplace.h` (`lp_id_to_xyz`, `lp_xyz_to_id`, `lp_xyz_spare`), `src/geometry.c` |
| Path vertex M | Exact integer-valued double: run bits `0..29` (30b), `said` role bits `30..32` (3b: `CLAIM=1`, `RECORD=2`, `TUPLE=3`, `METADATA=4`, `HOLDS=5`, `VOICE=6`, `DEPENDENCE=7`), outcome bits `33..34` (2b: `WIN=0`, `DRAW=1`, `LOSS=2`, `SCORE=3`), position bits `35..52` (18b) | `laplace.h` (`lp_m_run`, `lp_m_said`, `lp_m_outcome`, `lp_m_position`, `lp_m_full`), `consensus.h` |
| EWKB carrier | `POINT ZM` = 37 B (`0xC0000001`, single run); `LINESTRING ZM` = `9 + 32n` B (`0xC0000002`); always binary EWKB, never WKT | `src/geometry.c` |
| 64-bit `mask` | Single `uint64` / SQL `bit(64)` defined by `manifest/banks.tsv`: `kind` 8-bit flag set at bit 0 (`CLAIM`, `RECORD`, `TUPLE`, `FILE`), `upos` 5@8, `lexfile` 6@13, `deprel` 6@19, `vnrole` 6@25, `wnframe` 6@31 (enums store `slot + 1`, `0` = absent) | `manifest/banks.tsv`, `laplace.h` (`LP_MASK_BITS`), SQL `laplace_mask_*` |

### Why Mantissa Bit-Packing Exists (Never Conflate the Three Spaces)

1. **Identity, Sequence & Containment (`physicality.path` + GIN/B-tree/R-tree):** Packing 128-bit BLAKE3 child IDs + run/role/outcome/position into `POINT ZM` / `LINESTRING ZM` mantissas exploits 40+ years of battle-tested PostgreSQL/PostGIS storage, TOAST (`lz4`), binary `COPY`, and GIN/GiST indexing. It gives exact constituent order, RLE compression, `precedes` (`laplace_precedes`), `follows` (`laplace_follows`), gaps, co-occurrence, and LCA containment in microseconds **without** storing billions of `continues_to`/`contains` edge rows.
2. **4D Shape (`entity.coord` + Realized Curves):** Tier-0 DUCET/Super-Fibonacci points on $S^3$ and exact centroids inside the 4-ball (`entity.coord`), plus curves realized by unpacking constituent IDs and resolving their real `entity.coord` (`laplace_couple`, `laplace_project_path`) before measuring `laplace_frechet4d`, `laplace_dtw4d`, or `laplace_edr4d`. Never pass raw `physicality.path` carrier doubles into shape metrics or render carrier doubles directly on the glome (`ExploreDecomposeService.cs` / `GlomeCanvas.tsx` legacy bug).
3. **Meaning & Truth (`attestation` + `consensus` + Highway):** Curated witnesses and assimilated models assert n-ary claim compositions; per-witness game series fold into Glicko-2 `consensus` (`s_eff = 0.5 + t(s - 0.5)` bounded by witness trust and dependence root). Semantic navigation hops across rated claims and highway identifiers (`hop`, `translate`, `degrees`, `pull`, `turn`).

> [!WARNING]
> Legacy monorepo files (`Laplace/engine/core/src/mantissa.c` 212-bit `53/53/22` carrier, `hilbert4d.c` 128-bit key, `glicko2.c`, `hash128_merkle` domain byte, `SubstrateCanonicalIds.cs`) belong to the pre-modular substrate being retired under `one-substrate`. Never extend them; converge callers onto `Laplace-Native` + `Laplace-postgres`.

## 2. Extension Schema & In-Place Reconcile (`Laplace-postgres`)

- **Versioning (`CMakeLists.txt` + `laplace.control`):**
  - `laplace-storage:<16-hex>` hashes **only** `CREATE TYPE blake3` and the four persistent table DDLs in `sql/laplace.sql.in`.
  - `default_version` hashes the full install script, and the build emits `laplace.reconcile.sql` covering all replaceable functions, casts, operators, opclasses, and indexes (`path_set_match.sql` + `api.sql` + `operations.sql` + `laplace_restore_function_bindings()`).
  - `laplace deploy` (`Laplace-Engine/src/deploy.c` `prepare_laplace_transition`) checks storage compatibility and runs `ALTER EXTENSION laplace UPDATE TO ...` **in place**, preserving all ingested data and indexes whenever storage DDL is unchanged. Pass `--recreate` **only** when persistent table DDL or `tier0.bin` coordinates change.
- **Persistent tables (`sql/laplace.sql.in`):**
  - `entity(id blake3, tier smallint, coord geometry(PointZM), hilbert bigint, mask bit(64))` — PK `(tier, id)`, per-partition `UNIQUE (id)`; currently 9 tier range partitions `entity_t0`..`entity_t8plus` (note `Sequence/Conflicts.md` P4 vs `Sequence/Database.md` §8.10).
  - `physicality(entity blake3, tier smallint, hilbert bigint, path geometry, mask bit(64))` — PK `(tier, entity)`, FK `(tier, entity) → entity(tier, id) ON UPDATE CASCADE`, `parallel_workers=0`, `path SET STATISTICS 0`; 9 tier range partitions `physicality_t0`..`physicality_t8plus`.
  - `attestation(claim, witness, lineage, games, tokens, score, "position", trust)` — `UNIQUE NULLS NOT DISTINCT (claim, witness, lineage)`, 16 hex range partitions `attestation_0`..`attestation_f` (`fillfactor=80`).
  - `consensus(claim PK, rating, deviation, volatility, matches)` — 16 hex range partitions `consensus_0`..`consensus_f` (`fillfactor=80`).
- **Indexes (`sql/operations.sql` `laplace_schema_indexes()`):**
  - `entity_hilbert(hilbert)`, `entity_tier_hilbert(tier, hilbert, id)`, `entity_coord USING gist (coord laplace_point4d_ops)`, `entity_angular USING gist (coord laplace_angular4d_ops)`.
  - `physicality_paths USING gin (path laplace_path_ops, mask laplace_mask_ops) WITH (gin_pending_list_limit = 32768)`.
  - `physicality_assertions USING gin (path laplace_path_ops) WITH (gin_pending_list_limit = 32768) WHERE laplace_path_has_roles(path, 6)`.
  - `attestation_witness_lineage(witness, lineage NULLS FIRST) INCLUDE (trust)`.
- **Exported binding contract:** `Laplace-postgres/manifest/function_bindings.tsv` checked by `Laplace-postgres/tools/check-function-bindings.mjs`.

## 3. Engine Map (`Laplace-Engine/src`, 31 CLI Operations in `op.c`)

| Area | Files |
| :--- | :--- |
| CLI & SQL contract | `main.c`, `op.c` (31 operations + `describe`/`help`), `pg_contract.c`, `pg_plan.c`, `pg.c` (enforced by `tests/sql-contract-gate.py`) |
| Perf-caches & deploy | `tier0.c`, `flags.c`, `highway.c`, `chess_cache.c`, `deploy.c` (`deploy`, `index`, `status`, `projection`) |
| Recipes & Tree-sitter | `recipe.c`, `recipe_compile.c`, `structure_compile.c`, `structure_records.c`, `structure_decode.c`, `record_stream.c`, `grammars.c`, `recipes/` |
| Record VM & Node Table | `say.c`, `record_*.c`, `recipe_says.c`, `record_worker.h`, `table.c` (lock-free CAS + `compose` + cross-record `keys_put/get`) |
| Stage Load & Maintenance | `ingest.c`, `ingest_probe.c`, `db.c` (`prune`, `load`, `merge`), `db_metadata.c`, `forget.c` (`forget`, `sweep`), `replay` |
| Forward, Firmware & Domains | `firmware.c`, `program.c`, `pull.c`, `forward.c`, `read.c` (`pull`, `turn`, `said`, `hop`, `translate`, `degrees`, `fills`, `held`), `chess.c` (`pgn`, `tablebase`), `model.c` |

## 4. End-to-End Delivery Checklist (Definition of Done)

Never declare work done at compilation or unit tests alone. Complete the full loop for every layer touched:

1. **Build cleanly out-of-tree** (`icx-release`): `Laplace-Native` (`ctest --preset icx-release` when math/layouts change) → `Laplace-postgres` (`node tools/check-function-bindings.mjs`) → `Laplace-Engine` (`python tests/sql-contract-gate.py`) → `Laplace-MCP` / `Laplace` (`ReadPathArchitectureGateTests` when C#/SQL catalog touched).
2. **Deploy to the installed stack (in-place reconcile unless storage DDL changed):** `laplace-ops deploy -Target desktop` and `laplace-ops verify -Target desktop -Installed`.
3. **Execute the real feature end-to-end against installed PostgreSQL & real data** (`laplace`, `lpm` / MCP HTTP endpoint, or `/v1/*` Web/API route) and inspect actual outputs, timings, and plans (`Laplace-postgres/tests/deployed.sh`, `Laplace-Engine/tests/deployed/run.sh`, `Laplace-MCP/tests/deployed/run.sh`, `laplace-ops test -Check desktop-installed-deployment,desktop-installed-runtime`).
4. **Keep docs synchronized:** If you changed commands, schema, layouts, or operational workflows, update `Laplace-Wiki` (`python tools/check_wiki.py` and `npx markdownlint-cli2` — preserve exact `README.md` catalog summary parity) and `Laplace-Operations/agents/` (`pwsh -File Laplace-Operations/agents/sync.ps1`).
