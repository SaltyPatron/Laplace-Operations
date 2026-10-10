#!/bin/sh
# The ingest: the sources, in the order they go in, into the database laplace.env names. An operation of its own on a
# machine that is built and deployed (deploy.sh): it builds nothing, installs nothing and makes no database. What is
# recorded already is passed over by its trunk, so a run that was cut off is taken up by running it again.
#
#   ./ingest.sh                                  every source in recipes/order
#   ./ingest.sh open-english-wordnet verbnet     these sources, in the order given
#
# One ingest per database at a time. What each step said is kept in $LAPLACE_WORK/logs/ingest-runs.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
# one ingest per database at a time, whoever runs it (the operator, an agent): the second says so and leaves
db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p'); [ -w "$LAPLACE_LOCKS" ] || LAPLACE_LOCKS=$LAPLACE_WORK   # before setup.sh: this user's own
umask 002                                                                      # what this makes, every operator of the group may take up
lock=$LAPLACE_LOCKS/ingest-${db:-default}.lock
if [ -e "$lock" ] && [ ! -w "$lock" ]; then                                    # left by another operator without group write: theirs while it runs, stale after
  p=$(cat "$lock.pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "an ingest of $db is already running (pid $p): this one leaves"; exit 3; fi
  rm -f "$lock" "$lock.pid"; fi
exec 9>>"$lock"
flock -n 9 || { echo "an ingest of $db is already running (pid $(cat "$lock.pid" 2>/dev/null)): this one leaves"; exit 3; }
echo $$ > "$lock.pid"
log=$LAPLACE_WORK/logs/ingest-runs/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$log"
step(){ name=$1; shift; echo; echo "=== $name   $(date -u +%H:%M:%S)"
        { "$@" 2>&1; echo $? > "$log/$name.exit"; } | grep --line-buffered -v "^OMP: " | tee "$log/$name.log"
        [ "$(cat "$log/$name.exit" 2>/dev/null)" = 0 ] || { echo "=== $name did not finish; what it said is in $log/$name.log"; exit 1; }; }

command -v laplace >/dev/null || { echo "no laplace program on the path: deploy.sh builds it"; exit 1; }
[ -s "$LAPLACE_TIER0" ] && [ -s "$LAPLACE_HIGHWAY" ] || { echo "no perf-caches at $LAPLACE_TIER0: prepare or install them separately (README.md)"; exit 1; }

# What the log is made of while the ingest runs, by table and index: each minute, the minute before is read from the
# log while it still holds it (pg_walinspect: a checkpoint recycles what is older), and the totals are added up when
# the ingest ends. Full-page images and their bytes, and the bytes of the records' own data ($log/wal.tsv: time, the
# relation, its resource manager, blocks, full-page images, their bytes, data bytes). XLOG rows are hint-bit images.
sql(){ psql -X "$LAPLACE_CONNINFO" -Atq -F '	' -c "$1" 9>&-; }                  # 9>&-: no query outlives the ingest holding its lock
# Where pg_wal begins now: a minute of a heavy load can write more than max_wal_size, and a checkpoint recycles what is
# older, so a read starts no earlier than the oldest segment still there (its name is timeline, log, segment).
wal_oldest="SELECT (substr(n, 9, 8) || '/' || to_hex(('x' || substr(n, 17, 8))::bit(32)::bigint * pg_size_bytes(current_setting('wal_segment_size'))))::pg_lsn
              FROM (SELECT min(name) AS n FROM pg_ls_waldir() WHERE name ~ '^[0-9A-F]{24}\$') w"
wal_read(){ sql "WITH b AS (SELECT relfilenode, reldatabase, resource_manager, count(*) AS n, count(*) FILTER (WHERE block_fpi_length > 0) AS fpi,
                   coalesce(sum(block_fpi_length), 0) AS fb, coalesce(sum(block_data_length), 0) AS db
                 FROM pg_get_wal_block_info(GREATEST('$1'::pg_lsn, ($wal_oldest)), '$2', false) GROUP BY 1, 2, 3)   -- grouped first: millions of blocks, a few hundred groups
               SELECT now()::timestamp(0), coalesce(pg_partition_root(c.oid)::regclass::text, c.relname, 'relfilenode ' || b.relfilenode), b.resource_manager,
                 sum(b.n), sum(b.fpi), sum(b.fb), sum(b.db)
               FROM b LEFT JOIN pg_class c ON c.relfilenode = b.relfilenode AND b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
               GROUP BY 2, 3" >> "$log/wal.tsv" || echo "  the log from $1 to $2 was not read: recycled before it was" >&2; }
# The log is written faster than pg_get_wal_block_info reads it back, so each minute only its first 64 MB is read: a
# sample of where the log's bytes go, by table and index, never a total.
wal_sampler(){ while sleep 60; do from=$(cat "$log/wal.from"); to=$(sql "SELECT pg_current_wal_lsn()") || continue
                 wal_read "$from" "$(sql "SELECT LEAST('$to'::pg_lsn, '$from'::pg_lsn + 67108864)")"; echo "$to" > "$log/wal.from"; done; }
wal_stop(){ [ -n "${sampler:-}" ] || return 0; kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null || true; sampler=""   # killed: its status is not the ingest's
            from=$(cat "$log/wal.from"); wal_read "$from" "$(sql "SELECT LEAST(pg_current_wal_lsn(), '$from'::pg_lsn + 67108864)")"; }
wal_summary(){ [ -s "$log/wal.tsv" ] || { echo "  no log was read"; return 0; }
  printf '  %-44s %-8s %12s %10s %10s\n' relation kind 'page images' 'images GB' 'data GB'
  awk -F '\t' '{ k = $2 "\t" $3; n[k] += $5; f[k] += $6; d[k] += $7 }
    END { for (k in n) { split(k, a, "\t"); printf "%.0f\t  %-44s %-8s %12d %10.2f %10.2f\n", f[k] + d[k], a[1], a[2], n[k], f[k] / 2^30, d[k] / 2^30 } }' "$log/wal.tsv" |
    sort -t '	' -k1,1nr | head -30 | cut -f2-
  awk -F '\t' '{ n += $5; f += $6; d += $7 } END { printf "  every relation, in the sample (64 MB a minute): %d page images, %.2f GB of them; %.2f GB of data\n", n, f / 2^30, d / 2^30 }' "$log/wal.tsv"; }
sql "CREATE EXTENSION IF NOT EXISTS pg_walinspect" || exit 1
sql "SELECT pg_current_wal_lsn()" > "$log/wal.from"
wal_sampler 9>&- & sampler=$!                                  # 9>&-: the lock is the ingest's, never held on by the sampler or its sleep
trap wal_stop EXIT

# Where the time goes, measured on the run itself. The engine: perf samples every thread of the ingest and of each
# source's process (its children) 99 times a second for the whole run, as the user the runner is, so nothing attaches
# and no root is asked; reported by symbol (perf.txt). The database: pg_stat_statements is emptied as the ingest begins
# and its statements by total time are reported as it ends (statements.txt).
prof(){ if command -v perf >/dev/null 2>&1; then perf record -q -F 99 -o "$log/perf.data" -- "$@"; else "$@"; fi; }
perf_summary(){ [ -s "$log/perf.data" ] || { echo "  not profiled (no perf)"; return 0; }
  perf report -i "$log/perf.data" --stdio --sort comm,dso,symbol 2>/dev/null | grep -v -e '^#' -e '^$' | head -50 > "$log/perf.txt"; cat "$log/perf.txt"; }
statements_summary(){ sql "SELECT calls, round(total_exec_time / 1000) AS s, round(mean_exec_time::numeric, 2) AS ms, rows,
                             left(regexp_replace(query, '\s+', ' ', 'g'), 160) FROM pg_stat_statements
                           WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) ORDER BY total_exec_time DESC LIMIT 25" \
                        | tee "$log/statements.txt"; }
sql "SELECT pg_stat_statements_reset()" >/dev/null || echo "  pg_stat_statements was not emptied: the statements report counts from before this run" >&2

# shellcheck disable=SC2086
step ingest     prof laplace ingest ${*:-$LAPLACE_SOURCES}        # the sources named, or every source in order
wal_stop
step wal        wal_summary
step profile    perf_summary
step statements statements_summary
step status     laplace status
step bench      laplace bench
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
