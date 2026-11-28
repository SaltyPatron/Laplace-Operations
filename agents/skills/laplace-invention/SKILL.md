---
name: laplace-invention
description: Deep byte-level and operational reference for Laplace (identity, tiers, Tier-0, mantissa path carrier, 64-bit mask banks, schema, in-place reconcile, engine layout, and SDLC verification gates). Load for any Laplace task touching layouts, schema, ingest, retrieval, synthesis, UI, or documentation.
metadata:
  short-description: Laplace byte-level reference + SDLC anti-fake verification gates
---

# Laplace — Deep Reference

Truth hierarchy (`INVENTOR_RECORD.md` + `INVENTION.md` + decided `Sequence/Conflicts.md` > `Engineering/Boundaries.md` & `Standards.md` > code) and strict SDLC priority (`P0` → `P5`) live in `Laplace-Operations/agents/AGENTS.md`. Always check documentation and code together; when agent-written code contradicts the invention or fakes an operation, tear out the fake and fix the code.

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
| Hilbert key | 4D 16-bit Skilling + BMI2 `pdep`; SQL stores `h ^ 0x8000000000000000` so signed `bigint` sort = unsigned Hilbert order. Strictly for $S^3$ DUCET sequencing & page/range locality — never uniqueness (*"knowledge can occupy the same space"*; uniqueness is `blake3`, order is `physicality.path`) | `laplace.h` (`lp_hilbert4`, `lp_hilbert_key`), `src/isa/hilbert_bmi2.c` |
| Path vertex X/Y/Z | IEEE-754 binary64 with biased exponent 1021 (values in `[0.25, 0.5)`): low `43 + 43 + 42 = 128` mantissa bits carry child `lp_id`; upper `9 + 9 + 10 = 28` spare bits carry `4-bit tag + 24-bit payload` (e.g. `LP_SPARE_SCORE`: score $\times 2^{24}$) | `laplace.h` (`lp_id_to_xyz`, `lp_xyz_to_id`, `lp_xyz_spare`), `src/geometry.c` |
| Path vertex M | Exact integer-valued double: run bits `0..29` (30b), `said` role bits `30..32` (3b: `CLAIM=1`, `RECORD=2`, `TUPLE=3`, `METADATA=4`, `HOLDS=5`, `VOICE=6`, `DEPENDENCE=7`), outcome bits `33..34` (2b: `WIN=0`, `DRAW=1`, `LOSS=2`, `SCORE=3`), position bits `35..52` (18b) | `laplace.h` (`lp_m_run`, `lp_m_said`, `lp_m_outcome`, `lp_m_position`, `lp_m_full`), `consensus.h` |
| EWKB carrier | `POINT ZM` = 37 B (`0xC0000001`, single run); `LINESTRING ZM` = `9 + 32n` B (`0xC0000002`); always binary EWKB, never WKT | `src/geometry.c` |
| 64-bit `mask` | Single fixed 8-byte `uint64` / SQL `bigint` defined by `manifest/banks.tsv`: `kind` 8-bit flag set at bit 0 (`CLAIM`, `RECORD`, `TUPLE`, `FILE`), `upos` 5@8, `lexfile` 6@13, `deprel` 6@19, `vnrole` 6@25, `wnframe` 6@31 (enums store `slot + 1`, `0` = absent) | `manifest/banks.tsv`, `laplace.h` (`LP_MASK_BITS`), SQL `laplace_mask_*` |

### Why Mantissa Bit-Packing Exists (Never Conflate the Four Orthogonal Planes)

1. **Scale-Free 4D Address Handle (`entity`):** Every granularity of concept—a Tier-0 codepoint on $S^3$, `"255"`, a Tier-2 UAX #29 word, a Tier-3 idiom/C statement, a function AST, a book, or a `.git` repository root—resolves deterministically to **one `entity` record (`id`, exact `__int128` 4D `coord` in `[-1, 1]^4`, `tier`, 64-bit highway `mask`)**. `entity.mask` is strictly `manifest/banks.tsv` highway/grammatical acceleration bits—never turn origin or channel.
2. **Sequence, Containment & Salience (`physicality.path` + GIN `laplace_path_ops`):** Packing 128-bit BLAKE3 child IDs + `M` (`run`/`said`/`outcome`/`position`) into `POINT ZM` / `LINESTRING ZM` mantissas gives exact constituent order, RLE compression, `precedes`, `follows`, gaps, co-occurrence, LCA containment, and GIN posting-cardinality salience (`laplace_salience`: continuous $I(e) = -\log_2\frac{\text{df}(e)+1}{N+1}$, span contraction, `WIN`/`LOSS` differential) with zero edge tables.
3. **Directed 4D Shape (`entity.coord` + Realized Curves):** Permutations share a deterministic 4D centroid (`coord("cat") == coord("act") == coord("tac")`); monotone-forward `laplace_frechet4d`, `laplace_dtw4d`, and `laplace_edr4d` resolve forward direction on unpacked child `entity.coord` positions (`laplace_couple`, `laplace_project_path`). Geometry nominates structural candidates and carries **zero** semantic meaning.
4. **Meaning & Consequence (`attestation` + `consensus` + `trust_classes.toml`):** External sources, user prompts (`UserPromptContent` `0.30`), Laplace responses (`ResponseContent` `0.20`), internal reasoning/AST hypotheses (`InternalMonologue` `0.10`), and deterministic toolchain/verifier outcomes (`ToolchainVerification` `0.90`) all live in the same 4 tables, separated by trajectory vertex metadata and witness trust class.
5. **Pure State Trajectories & Altitude Inheritance (`Sequence/Conflicts.md` K2):** State-transition domains (such as chess) store pure canonical state sequences (`line = [P0, P1, …, Pn]`, with standard start `P0` as one canonical entity referenced across ~99% of games) attested **once at game altitude** with game outcome (`1-0` → `1.0`, `1/2-1/2` → `0.5`, `0-1` → `0.0`), eliminating synthetic per-move `[P_k, P_{k+1}]` win/loss explosions and 81-vertex `held` wrappers; move/position queries use GIN `laplace_path_ops` intersections and altitude inheritance, and annotated played games remain `K_PLAYED` retaining both outcome and clocks/NAGs/comments/variations—never interleaving move tuples, raw FEN/`[%clk]` strings, or KVP header bags (`["White", name]`).

## 2. Extension Schema & In-Place Reconcile (`Laplace-postgres`)

- **Versioning (`CMakeLists.txt` + `laplace.control`):**
  - `laplace-storage:<16-hex>` hashes **only** `CREATE TYPE blake3` and the four persistent table DDLs in `sql/laplace.sql.in`.
  - `default_version` hashes the full install script; build emits `laplace.reconcile.sql` covering replaceable functions, casts, operators, opclasses, and indexes (`path_set_match.sql` + `api.sql` + `operations.sql` + `laplace_restore_function_bindings()`).
  - `laplace deploy` (`Laplace-Engine/src/db/deploy.c`) runs `ALTER EXTENSION laplace UPDATE` **in place**, preserving admitted data and indexes whenever storage DDL is unchanged. Pass `--recreate` **only** when persistent table DDL or `tier0.bin` coordinates change.
- **Persistent tables (`sql/laplace.sql.in`):**
  - `entity(id blake3, tier smallint, coord geometry(PointZM), hilbert bigint, mask bigint)` — PK `(id, tier)` (no separate per-partition `entity_t*_id_key`); 9 tier range partitions `entity_t0`..`entity_t8plus`.
  - `physicality(entity blake3, tier smallint, path geometry, mask bigint)` — PK `(entity, tier)` (no separate per-partition `physicality_t*_entity_key`), FK `(entity, tier) → entity(id, tier) ON UPDATE CASCADE`, `parallel_workers=0`, `path SET STATISTICS 0`; 9 tier range partitions `physicality_t0`..`physicality_t8plus`.
  - `attestation(claim, witness, lineage, games, tokens, score, "position", trust)` — `UNIQUE NULLS NOT DISTINCT (claim, witness, lineage)`, nullable `trust` (`CHECK (trust IS NULL OR trust BETWEEN -1 AND 1)`), CHECK constraint `attestation_row_shape` separating canonical witness self-registration rows `(claim = witness, games = 0, tokens = 0, score = 0, "position" IS NULL, trust NOT NULL)` storing `(lineage, trust)` once per witness (registered via `laplace_register_witnesses(regclass)`) from compact claim testimony rows `(claim <> witness, games > 0, tokens >= games)` storing `lineage = NULL, trust = NULL` (saving 24 B/row; hydrated on read) unless an explicit per-claim `LP_SAID_DEPENDENCE` override applies; `laplace_attestation_count()` excludes `claim = witness` rows; 16 hex range partitions `attestation_0`..`attestation_f` (`fillfactor=80`).
  - `consensus(claim PK, rating, deviation, volatility, matches)` — 16 hex range partitions `consensus_0`..`consensus_f` (`fillfactor=80`).
- **Indexes (`sql/operations.sql` `laplace_schema_indexes()`):**
  - `entity_tier_hilbert(tier, hilbert, id)` (`entity_hilbert` dropped), `entity_coord USING gist (coord laplace_point4d_ops)` (32-byte outward-rounded `float32[8]` `laplace_box4d` keys; default `entity_angular` dropped).
  - `physicality_paths USING gin (path laplace_path_ops, mask laplace_mask_ops) WITH (gin_pending_list_limit = 32768)`.
  - `physicality_assertions USING gin (path laplace_path_ops) WITH (gin_pending_list_limit = 32768) WHERE laplace_path_has_roles(path, 6)`.
  - `attestation_witness_reg` (`CREATE UNIQUE INDEX attestation_witness_reg ON attestation (claim) INCLUDE (lineage, trust) WHERE claim = witness`, ~16 KB partial unique covering index replacing the 1.2 GB full-table `attestation_witness_lineage` index).
  - `consensus_standing(laplace_confidence(rating, deviation, 2) DESC, matches DESC, claim) WHERE matches > 0`.
- **Exported binding contract:** `Laplace-postgres/manifest/function_bindings.tsv` checked by `Laplace-postgres/tools/check-function-bindings.mjs`.

## 3. Engine Map (`Laplace-Engine/src`)

| Area | Directory & Key Files |
| :--- | :--- |
| Core, CLI & ROMs | `core/`: `main.c`, `op.c`, `tier0.c`, `flags.c`, `highway.c`, `fills.c`, `table.c`, `bench.c`, `reference_html.c` |
| DB, SQL Contract & Maintenance | `db/`: `pg.c`, `pg_contract.c`, `pg_plan.c`, `deploy.c`, `db.c`, `db_metadata.c`, `forget.c`, `read.c`, `read_ids.c`, `read_text.c`, `claim_read.c`, `provenance.c`, `walk.c`, `reader.h` |
| Recipes, Grammars & Ingest VM | `ingest/`: `ingest.c`, `ingest_probe.c`, `file.c`, `file_metadata.c`, `grammars.c`, `recipe.c`, `recipe_compile.c`, `recipe_decompose.c`, `recipe_says.c`, `say.c`, `structure*.c`, `record_*.c` |
| Media, Git & Toolchain Codecs | `codecs/`: `media_image.c`, `media_audio.c`, `media_video.c`, `parquet_decoder.c`, `shapefile.c`, `git_dag.c`, `toolchain_witness.c` |
| Forward, Firmware & OODA | `forward/`: `engine_abi.c`, `firmware.c`, `forward.c`, `program.c`, `program_couple.c`, `pull.c`, `pull_degrees.c`, `ooda.c` |
| Models & Mold-a-Model | `model/`: `model.c`, `mold.c`, `gguf_writer.c` |
| Chess & Syzygy | `chess/`: `chess.c`, `chess_cache.c`, `chess_pgn.c`, `chess_rules.c`, `chess_search.c`, `chess_syzygy.c`, `chess_tablebase.c` |

## 4. SDLC Verification & Anti-Fake Gate Checklist

Before considering any change complete under `P0` → `P5`, verify **every** applicable gate:

1. **Zero Ignored Parameters or Fake Lookups:**
   - Every SQL/API/C parameter (`shape`, `bands`, `lang`, `contextIds`, `format`, `structure`, `max_tokens`, `temperature`, `seed`, `scope`) must actually drive execution or return an explicit unsupported error.
   - Zero hardcoded dictionary chains (`@wn-lmf/Definition` shortcuts), zero `strstr()` compiler-log patch hacks, zero dummy identity/constant layer matrices, and zero C# reimplementations of C geometry/scoring.
2. **Client-ROM vs. In-DB C Split Honored:**
   - Pure deterministic operations (`lp_id`, UAX #29, `tier0.flags`, 4D centroids, Hilbert keys, EWKB packing, Syzygy probes, in-memory Fréchet/DTW/EDR, `lp_realize` over cached paths) run in `Laplace-Native` C (`Laplace.Native.Interop`) with `0` DB trips.
   - Index/heap intersections (`Laplace-postgres`) stay inside PostgreSQL shared buffers via prepared binary probes.
3. **Contract & Build Gates Pass:**
   - `Laplace-Native`: `ctest --preset icx-release`, `node tools/csharp/generate.mjs --check`, `csharp_abi`.
   - `Laplace-postgres`: `node tools/check-function-bindings.mjs`.
   - `Laplace-Engine`: `python tests/sql-contract-gate.py`.
   - `Laplace`: `dotnet build app/Laplace.slnx -warnaserror`, `ReadPathArchitectureGateTests`.
4. **Live Populated-Database Proof (P5 / end of change):**
   - No mocks, no `initdb` temp clusters. Prove real behavior against populated PostgreSQL 18 (`laplace` DB): coherent stateful `turn` / `/v1/chat/completions`, honest `ABSTAIN` on unwitnessed facts, real `llama.cpp` execution of exported checkpoints (`raw_weight_bytes_retained = 0`), real compiled/tested code repair, `fastchess` + `ordo` evaluation, and `SUM(share_bp) = 10000`.
5. **Real Browser Walkthrough (for any UI change):**
   - Walk every modified flow in the actual browser UI (`Laplace/web`): zero dead controls, zero silent broken tabs, zero quote gates blocking inspection, zero client-side regex masking backend noise.
6. **Docs & Sync:**
   - Keep `Laplace-Wiki` (`python tools/check_wiki.py`, `npx markdownlint-cli2`) and `Laplace-Operations/agents/` (`pwsh -File Laplace-Operations/agents/sync.ps1`) in sync with actual code, never committing status diaries or victory prose.
