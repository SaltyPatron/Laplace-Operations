#!/bin/bash
# tune-pg.sh's rules against the machines Laplace runs on, and the invariants every plan must keep: the memory promised
# never exceeds the memory there is. Facts are the hosts' as measured (2026-10-10): /proc/meminfo, the topology in
# sysfs, the volumes in the mount table. No connection, no server: the plan alone.
#
#   tests/tune-pg-plan.sh          every fixture, the invariants, and the plans side by side
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export LAPLACE_PGDATA=/data/pgdata LAPLACE_PGWAL=/data/pgdata/pg_wal LAPLACE_PG_DIR=/usr/local/pgsql LAPLACE_PGUSER=postgres LAPLACE_PGSERVICE=pgdata LAPLACE_LOCKS=/run/lock/laplace
export LAPLACE_CONNINFO="host=/tmp port=5432 user=laplace dbname=laplace"
G=$((1024 * 1024 * 1024))
#        name          profile    ram_kb     threads cores wal_bytes       shared rot reserved buffers_max
fixtures() { cat <<TSV
hart-server	substrate	131799160	12	6	$((64 * G))	0	0	0	0
hart-cloud	substrate	32862256	8	4	$((16 * G))	0	0	0	0
hart-prod	app	4007004	2	1	$((50 * G))	1	0	0	0
HART-DESKTOP	substrate	50037756	32	24	$((2000 * G))	1	0	34GB	1GB
one-core-hdd	app	2048000	1	1	$((20 * G))	1	1	0	0
TSV
}
fail=0
plan_of() {  # the plan's NAME=value lines for one fixture
  local name=$1 profile=$2 ram=$3 threads=$4 cores=$5 wal=$6 shared=$7 rot=$8 reserved=$9 cap=${10}
  LAPLACE_PG_PROFILE=$profile TUNE_FACT_RAM_KB=$ram TUNE_FACT_THREADS=$threads TUNE_FACT_CORES=$cores TUNE_FACT_WAL_BYTES=$wal TUNE_FACT_WAL_SHARED=$shared \
  TUNE_FACT_ROTATIONAL=$rot LAPLACE_PG_RESERVED=$reserved LAPLACE_PG_BUFFERS_MAX=${cap/#0/} bash -c '. "$1"; "$2"' tune-pg-plan "$here/tune-pg.sh" "${11:-plan}"
}
check() { if [ "$2" -le "$3" ] 2>/dev/null; then :; else echo "  FAIL $1: $2 > $3"; fail=1; fi; }
declare -A plans=()
while IFS=$'\t' read -r name profile ram threads cores wal shared rot reserved cap; do
  [ -n "$name" ] || continue
  p=$(plan_of "$name" "$profile" "$ram" "$threads" "$cores" "$wal" "$shared" "$rot" "$reserved" "$cap"); plans[$name]=$p
  v(){ sed -n "s/^$1=//p" <<<"$p"; }
  d=$(plan_of "$name" "$profile" "$ram" "$threads" "$cores" "$wal" "$shared" "$rot" "$reserved" "$cap" declared)
  if ! awk 'NF && $1 !~ /^#/ { if (seen[$1]++) { print "  FAIL duplicate setting: " $1; bad=1 } } END { exit bad }' <<<"$d"; then fail=1; fi
  declared_locks=$(awk '$1 == "max_locks_per_transaction" {print $2}' <<<"$d")
  [ "$declared_locks" = "$(v locks)" ] || { echo "  FAIL declared locks differ from plan on $name"; fail=1; }
  echo "$name ($profile): usable $(( $(v usable_kb) / 1024 )) MB of $((ram / 1024)), $(v conns) connections, $(v backends) backends"
  # the four domains: shared + private + client + page cache = usable; nothing promised twice
  check "shared_buffers within PostgreSQL's 40% of memory" "$(v shared_kb)" $((ram * 2 / 5))
  check "shared_buffers a quarter of what the server may use" "$(v shared_kb)" $(( $(v usable_kb) / 4 ))
  check "effective_cache_size within what the server may use" "$(v ecs_kb)" "$(v usable_kb)"
  # the private quarter: every backend's work_mem and temp_buffers, one maintenance operation, every autovacuum worker
  private=$(( $(v backends) * ( $(v work_nodes) * $(v work_kb) + $(v temp_kb) ) + $(v mwm_kb) + $(v avw) * $(v avwm_kb) ))
  actual_wal=$(awk '$1 == "wal_level" {print $2}' <<<"$d")
  expected_wal=minimal; [[ "$profile" != app ]] || expected_wal=replica
  [[ "$actual_wal" == "$expected_wal" ]] || { echo 'FAIL WAL mode differs from recovery profile'; fail=1; }
  # at PostgreSQL's floors (work_mem 4 MB, temp_buffers 8 MB) the declared backends may want more than the quarter: then the
  # plan says by how much (over_kb) instead of promising it, and nothing beyond that is promised
  over=$(( private - $(v private_kb) )); [ "$over" -gt 0 ] || over=0
  check "the backends' memory within the private quarter plus what the plan declares over-committed (${private} kB)" "$private" $(( $(v private_kb) + $(v over_kb) ))
  [ "$(v over_kb)" = "$over" ] || { echo "  FAIL over-commitment reported as $(v over_kb) kB, is $over kB"; fail=1; }
  [ "$over" = 0 ] || echo "  over-committed by $(( over / 1024 )) MB at the floors: declared, not promised"
  check "wal_buffers within max_wal_size/16" "$(v wal_buf_kb)" $(( $(v wal_mb) * 1024 / 16 ))
  check "min_wal_size below max_wal_size" "$(v min_wal_mb)" "$(v wal_mb)"
  check "max_wal_size within half the log's volume" "$(v wal_mb)" $(( wal / 1048576 / 2 > 1024 ? wal / 1048576 / 2 : 1024 ))
  check "parallel workers on the cores" "$(v par)" "$cores"
  check "a gather's workers at most half the cores" "$(v gather)" $(( cores / 2 ))
  check "io_workers within PostgreSQL's 32" "$(v iow)" 32
  check "parallel workers within max_worker_processes" "$(v par)" "$(v mwp)"
  [ "$(v work_kb)" -ge 4096 ] || { echo "  FAIL work_mem below its 4 MB floor"; fail=1; }
  [ "$(v conns)" -ge 16 ] || { echo "  FAIL fewer than 16 connections"; fail=1; }
  if [ "$rot" = 1 ]; then [ "$(v rpc)" = 4 ] || { echo "  FAIL random_page_cost on a rotating disk is 4"; fail=1; }; fi
  if [ "$cap" != 0 ]; then check "shared_buffers within LAPLACE_PG_BUFFERS_MAX" "$(v shared_kb)" $((1024 * 1024)); fi
done < <(fixtures)
echo
printf '%-34s' "setting"; for n in hart-server hart-cloud hart-prod HART-DESKTOP; do printf '%14s' "$n"; done; echo
for k in shared_kb ecs_kb work_kb mwm_kb avwm_kb temp_kb wal_buf_kb wal_mb min_wal_mb conns backends par gather iow mwp avw locks; do
  printf '%-34s' "$k"; for n in hart-server hart-cloud hart-prod HART-DESKTOP; do printf '%14s' "$(sed -n "s/^$k=//p" <<<"${plans[$n]}")"; done; echo
done
[ "$fail" = 0 ] && echo "tune-pg plans: every invariant holds" || { echo "tune-pg plans: FAILED"; exit 1; }
