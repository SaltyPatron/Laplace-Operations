# Windows Zstd decoder repair

On 2026-10-22, HART-DESKTOP's PostgreSQL 18.6 crash recovery failed with
`corrupted line pointer: 30854` while replaying a heap pruning record.
The preceding Zstd-compressed full-page WAL image was valid. Both locally
built Zstd 1.5.7 DLLs decoded four zero bytes incorrectly. An independent
decoder reconstructed the page correctly.

Rebuilding the same pinned source with the declared IntelLLVM toolchain
and `/clang:-fno-vectorize` produced the exact reference output. PostgreSQL's
own `pg_waldump` using that rebuilt DLL produced the same 8192-byte page.
The per-dependency option retains `/O2`, inlining and SLP vectorization.

`tests/windows-zstd.ps1` tests a selected actual DLL without accessing a
database or stopping PostgreSQL. Its C probe generates 4096 overlapping
short-match cases followed by 12000 deterministic inputs at compression
levels 1, 3 and 9, checking decoded bytes and output bounds. The old DLL
fails short-match case 450 at byte 297; the rebuilt DLL passes all cases.
The regression contains no database contents or captured WAL.

`setup.ps1` records the changed Zstd dependency contract, rebuilds stale
installations, and requires the DLL regression before acceptance. Runtime
closure verifies replacement codec DLLs before stopping a running service,
backs up the installed copy, refreshes the PostgreSQL-adjacent DLL and
checks it again. Copy or regression failure restores the old binary.

Run `tests/windows-zstd.ps1 -Library <absolute-dll-path>` for an explicit
library, or the named `zstd-windows-roundtrip` acceptance check for the
declared PostgreSQL runtime. PostgreSQL startup and completed WAL replay
must be checked separately after installing the corrected DLL.
