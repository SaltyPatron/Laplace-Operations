#!/bin/bash
# The server's settings, converged and checked. declared() is the set. setup.sh settings
# is this same set when a person runs it as root. deploy.sh runs this on every deployment,
# as the role: the role is superuser, so ALTER SYSTEM needs no root. A drift fails the run.
# A setting that needs a restart is restarted only when this user may restart the unit and
# no ingest holds the lock.
#
# The monorepo phase tune-pg (scripts/pipeline.sh, laplace_admin) targets the old substrate
# and a different cluster. It is not this server.
#
#   ./tune-pg.sh           apply what differs, reload, check
#   ./tune-pg.sh --check   report drift, change nothing
set -euo pipefail
_tune_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -n "${LAPLACE_PGDATA:-}" ] || . "$_tune_here/laplace.env"
# A workflow that exports an empty LAPLACE_CONNINFO must still get this file's default.
# ${VAR:-default} does not fill an empty string.
if [ -z "${LAPLACE_CONNINFO:-}" ]; then
  LAPLACE_CONNINFO="host=/tmp port=5432 user=${LAPLACE_ROLE:-laplace} dbname=laplace"
fi
PGWAL=${PGWAL:-$LAPLACE_PGWAL}
PGBIN=${PGBIN:-$LAPLACE_PG_DIR/bin}
PGUSER=${PGUSER:-$LAPLACE_PGUSER}
SERVICE=${SERVICE:-$LAPLACE_PGSERVICE}
TUNE_CONN=$(printf '%s' "$LAPLACE_CONNINFO" | sed 's/dbname=[^ ]*/dbname=postgres/')
case $TUNE_CONN in *dbname=*) ;; *) TUNE_CONN="$TUNE_CONN dbname=postgres" ;; esac

# Memory follows the machine. nproc reports OMP_NUM_THREADS when a shell has set it.
ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
cores=$(env -u OMP_NUM_THREADS -u MKL_NUM_THREADS nproc)
# The log's bound is the volume it is on. max_wal_size is the checkpoint target, not a
# directory quota: the log runs past it while a checkpoint catches up, and a target equal
# to the volume filled it and stopped the server. Half the volume leaves a reserve the
# size of the target. On 2026-10-03 the three-eighths target (24 GB) started a checkpoint
# from WAL 35 times and from the timer never; distance sat at 13–21 GB, and after 18:29
# the counters were 170 GB and 36 million full-page images with num_timed still 0.
# A replication slot is held to the same bound. The block device, from the mount table
# and sysfs: findmnt's SIZE and df both stat the mount, and the data directory is not
# readable by the role that deploys.
wal_bytes() {
  local src dev base sectors
  src=$(awk -v m="$PGWAL" '$2==m {print $1; exit}' /proc/mounts)
  [ -n "$src" ] || { echo "tune-pg: $PGWAL is not mounted" >&2; return 1; }
  dev=$(readlink -f "$src"); base=$(basename "$dev")
  sectors=$(cat "/sys/class/block/$base/size")
  echo $(( sectors * 512 ))
}
wal_mb() { echo $(( $(wal_bytes) / 1048576 / 2 )); }
# wal_compression zstd: on 23,450 of ConceptNet's B-tree images, level 3 wrote 3,781 bytes
# a page against lz4's 4,711, at 57 us a page against 17.
# wal_level minimal (SQL Server's simple recovery, not full): nothing reads this server's log
# but its own crash recovery (no standby, no slot, no archive, no base backup). At minimal a
# table truncated or made in a transaction is written without WAL, its indexes with it, and
# synced at commit or PREPARE instead: laplace merge rewrites a leaf partition that way. From
# 2026-10-03 18:29, 190 GB of log were written, 36.0 million of its records full-page images.
# PostgreSQL reads wal_level at start only, and will not start at minimal unless
# max_wal_senders is 0.
declared() { cat <<SET
wal_level                        minimal
max_wal_senders                  0
shared_buffers                   $((ram_kb / 4 / 1024 / 1024))GB
effective_cache_size             $((ram_kb * 7 / 10 / 1024 / 1024))GB
work_mem                         256MB
maintenance_work_mem             8GB
huge_pages                       try
io_method                        worker
io_workers                       $((cores * 2 / 3))
effective_io_concurrency         256
maintenance_io_concurrency       256
random_page_cost                 1.1
default_toast_compression        lz4
max_wal_size                     $(wal_mb)MB
max_slot_wal_keep_size           $(wal_mb)MB
min_wal_size                     4GB
wal_buffers                      256MB
wal_compression                  zstd
checkpoint_timeout               60min
checkpoint_completion_target     0.9
bgwriter_lru_maxpages            1000
max_worker_processes             $((cores + 4))
max_parallel_workers             $cores
max_parallel_workers_per_gather  $((cores / 2))
max_parallel_maintenance_workers $((cores / 2))
jit                              off
enable_parallel_append           on
gin_pending_list_limit           32MB
autovacuum_max_workers           $((cores / 2 < 3 ? 3 : cores / 2))
autovacuum_naptime               10s
autovacuum_vacuum_cost_delay     0
autovacuum_vacuum_cost_limit     2000
autovacuum_vacuum_scale_factor   0.05
autovacuum_analyze_scale_factor  0.02
autovacuum_vacuum_insert_scale_factor 0.01
autovacuum_work_mem              1GB
shared_preload_libraries         pg_stat_statements,auto_explain
pg_stat_statements.track         all
auto_explain.log_min_duration    5s
track_io_timing                  on
track_wal_io_timing              on
temp_tablespaces                 pgtemp
listen_addresses                 *
ssl                              on
port                             5432
max_connections                  100
max_prepared_transactions        32
SET
}

tune_ingesting() {
  local db l
  db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p')
  l=${LAPLACE_LOCKS:-/run/lock/laplace}/ingest-${db:-default}.lock
  [ -e "$l" ] && ! flock -n "$l" true
}

tune_psql() {
  local f out rc
  f=$(mktemp)
  chmod 644 "$f"
  printf '%s\n' "$1" >"$f"
  if [ "$(id -u)" = 0 ]; then
    out=$(su "$PGUSER" -c "$PGBIN/psql -X -h /tmp -d postgres -v ON_ERROR_STOP=1 -At -F '|' -f $f" </dev/null) && rc=0 || rc=$?
  else
    out=$(psql -X "$TUNE_CONN" -v ON_ERROR_STOP=1 -At -F '|' -f "$f") && rc=0 || rc=$?
  fi
  rm -f "$f"
  printf '%s\n' "$out"
  return "$rc"
}

# name|match|context|source|pending|live. match is the value only; pending is separate,
# so a value already in force is not written again just because a restart is owed.
tune_report_sql() {
  local vals="" name value
  while read -r name value; do
    [ -n "$name" ] || continue
    value=${value//\'/\'\'}
    vals="${vals}('${name}','${value}'),"
  done < <(declared)
  vals=${vals%,}
  cat <<SQL
WITH want(name, value) AS (VALUES ${vals}),
p AS (
  SELECT w.name, w.value,
         substring(w.value from '^(-?[0-9.]+)')::numeric AS n,
         nullif(substring(lower(w.value) from '[a-z]+\$'), '') AS u
  FROM want w
)
SELECT w.name,
       CASE
         WHEN s.name IS NULL THEN 'f'
         WHEN s.vartype = 'bool' THEN
           CASE WHEN current_setting(w.name) =
             CASE lower(w.value) WHEN 'on' THEN 'on' WHEN 'true' THEN 'on' WHEN '1' THEN 'on' WHEN 'yes' THEN 'on'
                                 WHEN 'off' THEN 'off' WHEN 'false' THEN 'off' WHEN '0' THEN 'off' WHEN 'no' THEN 'off'
                                 ELSE w.value END
           THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND coalesce(s.unit, '') = '' THEN
           CASE WHEN abs(s.setting::numeric - p.n) < 0.0000001 THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND s.unit ~ 'B\$' THEN
           CASE WHEN s.setting::numeric = round(pg_size_bytes(w.value)::numeric
              / pg_size_bytes(CASE WHEN s.unit ~ '^[0-9]' THEN s.unit ELSE '1 ' || s.unit END)) THEN 't' ELSE 'f' END
         WHEN s.vartype IN ('integer', 'real') AND s.unit IN ('us','ms','s','min','h','d') THEN
           CASE WHEN s.setting::numeric * CASE s.unit WHEN 'us' THEN 0.001 WHEN 'ms' THEN 1 WHEN 's' THEN 1000 WHEN 'min' THEN 60000 WHEN 'h' THEN 3600000 WHEN 'd' THEN 86400000 END
                     = p.n * CASE coalesce(p.u, s.unit) WHEN 'us' THEN 0.001 WHEN 'ms' THEN 1 WHEN 's' THEN 1000 WHEN 'min' THEN 60000 WHEN 'h' THEN 3600000 WHEN 'd' THEN 86400000 END
           THEN 't' ELSE 'f' END
         ELSE
           CASE WHEN replace(current_setting(w.name), ' ', '') = replace(w.value, ' ', '') THEN 't' ELSE 'f' END
       END,
       coalesce(s.context, ''),
       coalesce(s.source, ''),
       CASE WHEN s.pending_restart THEN 't' ELSE 'f' END,
       coalesce(current_setting(w.name, true), '')
FROM want w
LEFT JOIN pg_settings s ON s.name = w.name
LEFT JOIN p ON p.name = w.name
ORDER BY 1;
SQL
}

tune_apply() {
  declare -A want=()
  local name value match context source pending live n=0
  while read -r name value; do [ -n "$name" ] && want[$name]=$value; done < <(declared)
  while IFS='|' read -r name match context source pending live; do
    [ -n "$name" ] || continue
    # Already the declared value and already recorded, or a postmaster knob already in force:
    # writing that again can mark a restart for a value the server is already running.
    if [ "$match" = t ] && { [ "$source" = "configuration file" ] || [ "$context" = postmaster ]; }; then
      continue
    fi
    value=${want[$name]}
    if ! tune_psql "ALTER SYSTEM SET $name = '${value//\'/\'\'}'" >/dev/null; then
      echo "tune-pg: REFUSED $name $value" >&2
      return 1
    fi
    echo "tune-pg: set $name = $value"
    n=$((n + 1))
  done < <(tune_psql "$(tune_report_sql)")
  [ "$n" = 0 ] || tune_psql "SELECT pg_reload_conf()" >/dev/null
  echo "tune-pg: $(declared | grep -c .) declared, $n set"
}

tune_restart() {
  local pending unit i
  pending=$(tune_psql "SELECT coalesce(string_agg(name, ', ' ORDER BY name), '') FROM pg_settings WHERE pending_restart")
  [ -n "$pending" ] || return 0
  if tune_ingesting; then
    echo "tune-pg: restart for $pending DEFERRED: an ingest is running" >&2
    return 1
  fi
  unit="${SERVICE}.service"
  if [ "$(id -u)" = 0 ]; then
    systemctl restart "$unit"
  elif sudo -n systemctl restart "$unit"; then
    :
  else
    echo "tune-pg: $pending pending_restart; $unit was not restarted" >&2
    return 1
  fi
  for i in $(seq 120); do
    if [ "$(id -u)" = 0 ]; then
      su "$PGUSER" -c "$PGBIN/pg_isready -q -h /tmp" </dev/null && return 0
    else
      pg_isready -q -h /tmp && return 0
    fi
    systemctl is-active -q "$unit" || { echo "tune-pg: $unit stopped" >&2; return 1; }
    sleep 1
  done
  echo "tune-pg: $unit did not accept connections" >&2
  return 1
}

tune_check() {
  local bad=0 name match context source pending live n=0
  while IFS='|' read -r name match context source pending live; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$match" != t ] || [ "$pending" = t ]; then
      echo "tune-pg: $name = '$live' source=$source pending=$pending" >&2
      bad=1
    fi
  done < <(tune_psql "$(tune_report_sql)")
  [ "$n" = "$(declared | grep -c .)" ] || { echo "tune-pg: $n of $(declared | grep -c .) settings read" >&2; return 1; }
  [ "$bad" = 0 ] || return 1
  echo "tune-pg: $n settings match"
}

tune_main() {
  case ${1:-} in
    --check) tune_check ;;
    "") tune_apply; tune_restart; tune_check ;;
    *) echo "usage: tune-pg.sh [--check]" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  tune_main "${1:-}"
fi
