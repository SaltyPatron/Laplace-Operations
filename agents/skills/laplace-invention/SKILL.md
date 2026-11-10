---
name: laplace-invention
description: Deep byte-level and operational reference for Laplace (identity, tiers, Tier-0, path carrier, banks, schema, ingest, MCP research recipes, verification checklist). Load for any Laplace task that touches layouts, schema, ingest, retrieval, or documentation accuracy.
metadata:
  short-description: Laplace byte-level reference + research recipes
---

# Laplace — Deep Reference

The core laws and repo map are in the global agent file (`Laplace-Operations/agents/AGENTS.md`). This skill adds byte-level detail, research recipes, and a verification checklist. **Every number here was verified against code on 2026-11-09. Re-verify anything you're about to depend on** — the "where to verify" column says where.

## 1. Byte layouts

| Thing | Layout | Where to verify |
| :--- | :--- | :--- |
| `lp_id` | `uint8_t b[16]` = BLAKE3-256 prefix; printed as 32 lowercase hex digits | `laplace.h` (`lp_id`, `lp_id_codepoint`, `lp_id_compose`) |
| Composition | n==1 → child itself; n≥2 → BLAKE3-128(child ids ‖ …), `tier = lp_tier_above` = 1+max (saturates at 255) | `src/compose.c` (`lp_ref_compose`), `laplace.h` `lp_tier_above` |
| `lp_tier0_record` (64 B) | `id[16]`, `int64 m[4]` (value m/2^53), `uint64 hilbert`, `uint32 rank` (DUCET), `uint32 pad` | `laplace.h`, `src/tier0.c` |
| Tier-0 shards | ascii 128 · utf 22,112 · cjk 115,920 · ext 975,952 records; `LAPLACE_TIER0_PROFILE` tokens `ascii`, `utf`/`latin` (=ascii+utf), `utf-only`, `cjk` (=bmp), `cjk-only`, `bmp`, `ext`/`supplementary`/`planes`, `full`/`all`; fallback `LAPLACE_TIER0_BRANCHES`; `@profile` path suffix | `tier0.h`, `src/tier0_map.c` |
| Flags | 32 B (256 bits) per codepoint + `.layout`; shards `<stem>.flags.<shard>.bin` | `laplace.h` `lp_flags`, `src/flags.c` |
| Highway | shards `core` (banks), `wordnet` (ILI), `frames` (roles); profile tokens `core`/`banks`, `wordnet`/`ili`, `frames`/`roles`, `lexical`/`full`/`all`; `LAPLACE_HIGHWAY_PROFILE` (fallback `LAPLACE_HIGHWAY_BRANCHES`) | `highway.h`, `src/highway.c` |
| Centroid | Σ m in `__int128`, divided by n truncating toward zero | `src/coord.c`, `internal.h` `lp_div128` |
| Inside test | Σ m_d² ≤ 2^106 (`lp_coord_inside`); Tier-0 nudged inward | `src/coord.c`, `src/tier0.c` |
| Hilbert | 4D 16-bit Skilling + `pdep`; SQL stores `h ^ 0x8000000000000000` | `laplace.h` `lp_hilbert_key`, `src/isa/hilbert_bmi2.c` |
| Path vertex X/Y/Z | Biased exponent 1021 (values in [0.25, 0.5)); low 43/43/42 mantissa bits = the 128-bit child ID; the 9+9+10 = 28 spare bits = 4-bit tag + 24-bit payload (e.g. `LP_SPARE_SCORE`: score × 2^24) | `laplace.h` `lp_id_to_xyz`/`lp_xyz_to_id`/`lp_xyz_spare`, `src/geometry.c` |
| Path vertex M | Integer-valued double: run bits 0–29 (`LP_M_RUN_BITS`), said bits 30–32 (`LP_M_SAID_BITS`), outcome bits 33–34, position bits 35–52 (18 bits). `lp_m_run`, `lp_m_said`, `lp_m_outcome`, `lp_m_position`, `lp_m_full` | `laplace.h` |
| `LP_SAID_*` | CLAIM 1, RECORD 2, TUPLE 3, METADATA 4, HOLDS 5, VOICE 6, DEPENDENCE 7 | `laplace.h`, `consensus.h` |
| Outcome | WIN 0 (also every non-claim), DRAW 1, LOSS 2, SCORE 3 (value in spare bits) | `laplace.h` |
| EWKB | POINT ZM 37 B (`0xC0000001`); LINESTRING ZM 9+32n B (`0xC0000002`); always binary, never WKT | `src/geometry.c` |
| Mask carrier | One `uint64` / `bit(64)`. `banks.tsv` gives the fields: `kind` 8 bits at 0 (row-role flags: CLAIM, RECORD, TUPLE, FILE), `upos` 5@8, `lexfile` 6@13, `deprel` 6@19, `vnrole` 6@25, `wnframe` 6@31. Enums store slot+1. Carriers: kind=row, upos/lexfile/wnframe=entity, deprel/vnrole=occurrence | `manifest/banks.tsv`, `laplace.h` `LP_MASK_BITS`, SQL `laplace_mask_*` |

### The path carrier: what it is for

Packing the ID into X/Y/Z gives each vertex three "entity coordinates" that *are* its identity, plus an M coordinate that holds metadata. Everything PostGIS knows about storing, copying, TOASTing and indexing geometry then works on ordered ID sequences:

- **Identity:** exact vertex match. An R-tree/GiST probe on a point is an exact ID lookup. GIN `laplace_path_ops` posts each vertex ID, which gives containment.
- **Metadata in M:** RLE run length, role, outcome and position. M-range predicates (`ST_LocateBetween`, `ST_FilterByM`) slice vertices by position first, then by outcome, said and run, because that is the bit order from high to low.
- **Not shape:** the axes are hash bits, so carrier closeness means nothing. A multi-vertex bounding box covers almost the whole [0.25, 0.5)³ cube and prunes nothing. Shape (the 4D form of the DAG segment) always realizes child coordinates first (`laplace_couple`, `laplace_project_path`). The raw `laplace_frechet4d` / `dtw4d` / `edr4d` measure whatever geometry they are handed.
- **Three kinds of "near", never conflated:**
  1. *Identity/containment*: the carrier and GIN.
  2. *Shape*: real 4D coordinates and realized trajectories. This is compositional/morphological similarity, not semantic.
  3. *Meaning*: attestations, relations, usages, observations, examples and highway identifiers, weighted by Glicko-2 consensus.

> [!WARNING]
> The monorepo has a **second, different carrier**: `Laplace/engine/core/src/mantissa.c` `mantissa_pack` (exponent 1023, sign + 52-bit mantissa = 53 payload bits; Z = 22 hash bits + 31 flag bits), exposed through `extension/laplace_geom` (`laplace_mantissa_pack`). The web glome (`web/src/explore/glome/GlomeCanvas.tsx` `unpackMantissaCoord`) decodes both formats. Its Native branch treats M as "51-bit run count", which is wrong. Do not assume paths are interchangeable between the `laplace` and `laplace-mono` databases.

## 2. Schema snapshot (`Laplace-postgres/sql/laplace.sql.in`, `operations.sql`; version in `laplace.control`)

- At verification time the version was 1.63. The `laplace--<v>.sql` file is generated by CMake from `sql/laplace.sql.in` (assembled from `api.sql` + `operations.sql` + `path_set_match.sql`), along with direct upgrade scripts.
- `entity(id blake3, tier smallint, coord geometry(PointZM), hilbert bigint, mask bit(64) CHECK laplace_mask_valid)`: 256 partitions. No `lexical`/`kind` columns.
- `physicality(entity blake3 PK → entity, tier, hilbert, path geometry, mask bit(64))`: 256 partitions, `parallel_workers=0`.
- Indexes:
  - `entity_coord` GiST `laplace_point4d_ops`, `entity_angular` `laplace_angular4d_ops`, `entity_hilbert`, `entity_tier_hilbert(tier,hilbert,id)`.
  - `physicality_paths` GIN `(path laplace_path_ops, mask laplace_mask_ops)`. Read `gin_pending_list_limit` from `operations.sql`; it was 32768.
  - Partial GIN `physicality_assertions WHERE laplace_path_has_roles(path,6)`.
- `consensus(claim PK, rating, deviation, volatility float8, matches bigint)`: 16 partitions, fillfactor 80.
- Witness = the source trunk node itself; no witness table (HEAD still has one; the in-progress work removes it). Physicalities are usages, observations and examples, **not attestations**. `attestation` is its own table, one row per (claim, witness, lineage) with games, tokens, score, position and trust (in progress). `consensus` folds the attestations per claim.
- Staging API: `laplace_ensure_stage`, `laplace_merge_stage`, `laplace_enrich_stage`, `laplace_clean_stage`, `laplace_stage_retire`/`_own`, `laplace_present_stage`, `laplace_accumulate_series`, `laplace_attest_stage`, `laplace_contained_series`, `laplace_clean_partitions`. `laplace_attest_series` is used by replay. `laplace_clean_pending_list` exists.
- Reads: `laplace_containers`, `laplace_paths`, `laplace_claims`, `laplace_follows`, `laplace_couple`, `laplace_distance4d`, `laplace_attested`, `laplace_attribution`, `laplace_bank_bit` (smallint), mask operators `?` `?&` `?|` (bit vs smallint / smallint[]), `laplace_text_id` (UAX #29 in SQL), `laplace_recoordinate`.
- Function contracts are the `COMMENT ON FUNCTION` blocks at the end of `laplace.sql.in`; `manifest/function_bindings.tsv` lists the exported Native symbols; `tools/check-function-bindings.mjs` checks the two agree.

## 3. Engine module map (`Laplace-Engine/src`)

| Concern | Files |
| :--- | :--- |
| CLI dispatch | `main.c` → `op.c` command table (`op_named`); built-ins `describe`, `help <cmd>` |
| Recipes | `recipe.c` (parse/select/order), `recipe_compile.c` (`say_compile`), `structure_compile.c` (TS symbol/field binding), `recipe_program.h` (bytecode) |
| Records | `structure_records.c` (record slicing), `record_stream.c` (windows, barriers), `recipe_decompose.c` (`decompose_input`; legacy `read_all` for non-streamable recipes), `structure_decode.c` (injected sub-grammars) |
| VM | `say.c` (`record_execute`), `record_values.c`, `record_things.c`, `record_operands.c`, `record_select.c`, `record_output.c`, `record_surface.c`, `record_journal.c`, `record_diagnostics.c`, `recipe_says.c`, `record_worker.h` |
| Tree-sitter | `grammars.c` (`lp_tls_parser`, `lp_tls_cursor`), grammars in `recipes/formats/grammars/` |
| Table | `table.c` (`compose`, `table_find`, `keys_put/get`, `table_reset`) |
| Load | `db.c` (`prune`, `load`, `copy_rows`, `merge`, `cmd_merge`), `db_metadata.c` (`start_loader`, `fold_events`, `flush_series`), `pg.c` |
| Ingest driver | `ingest.c`, `ingest_probe.c` (`--plan`) |
| Reads | `read.c`, `pull.c`, `forward.c`, `program.c`, `walk.c`, `provenance.c` |
| Chess / models | `chess.c`, `model.c` |

## 4. Research recipes (laplace-code MCP)

- **"Where is X defined / who calls it?"** `code_where {query: "symbol"}`, then `code_callers` / `code_callees`, then `file_outline {path}`.
- **"How does concept Y work?"** `code_search {query, scope: "docs", limit: 5}` for the spec, then the same query with `scope: "code"` for the implementation. Compare the two and report drift.
- **"Is the doc still true?"** `code_search` for each symbol the doc cites. Any missing symbol means stale.
- **"What's loaded / is an ingest running?"** `ingest_status {source?}`. On staging, also read `/repos/work/logs/ingest-runs/<UTC>/`.
- **"Does a recipe cover this source?"** `recipe_catalog`, then `recipe_plan {source}`.
- **Exercise the read path:** `search`, `hop`, `translate`, `degrees`, `pull`, `forward`, `turn`. Unexpected results here are bugs worth reporting, not noise.
- Exact-string lookups are faster with `git -C <repo> grep -n "<sym>"` (ripgrep is not installed on HART-DESKTOP).

## 5. Verification checklist before claiming "done"

1. Native: `ctest --preset icx-release` in `Laplace-Native` (`test_tier0` needs `$LAPLACE_TIER0`).
2. postgres: build `laplace_pg`, then `ctest` (`postgres_regress`, `module_install`). New SQL needs a regression case in `tests/regression_cases.txt`.
3. Engine: build `laplace_engine` plus the affected `EXCLUDE_FROM_ALL` test targets; `laplace ingest --plan` / `--claims` against a fixture in `tests/fixtures/`.
4. Monorepo: `ReadPathArchitectureGateTests` must pass (zero hand-written SQL).
5. Wiki: `python3 tools/check_wiki.py` and `npx markdownlint-cli2`.
6. Doc or agent edits: every cited path or symbol exists (grep it).
