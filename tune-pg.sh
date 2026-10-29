#!/bin/bash
# The server's settings, derived from the machine that runs it, converged and checked. declared() is the set. setup.sh
# settings is this same set when a person runs it as root; setup.sh appdb is it again for the application cluster
# (LAPLACE_PG_PROFILE=app). deploy.sh runs this on every deployment, as the role: the role is superuser, so ALTER SYSTEM
# needs no root. A drift fails the run. A setting that needs a restart is restarted only when this user may restart the
# unit and no ingest holds the lock.
#
#   ./tune-pg.sh           apply what differs, reload, check
#   ./tune-pg.sh --check   report drift, change nothing
#   ./tune-pg.sh --plan    the facts read from this machine and every setting they give; no connection
#
# One rule set, every machine its own numbers. The facts are read, not declared: the memory (and a cgroup's limit when
# it is lower), the logical processors and the physical cores they sit on, the volume holding the write-ahead log and
# whether it is the log's own, whether the data's device rotates. What a machine cannot say is declared in its
# machine.env with the measurement that set it: LAPLACE_PG_RESERVED (memory its other residents keep: HART-DESKTOP's
# llama-servers), LAPLACE_PG_BUFFERS_MAX (the largest shared memory a build maps: Windows), LAPLACE_PG_PROFILE
# (substrate: the server shares the host with the ingest client, the build and the agent; app: with the API, the MCP
# and the agent; what differs is the connection plan), LAPLACE_PG_SERVING (the connections the host's services hold).
#
# The memory is one equation in four domains (the monorepo's PostgresResourcePlan, which the laplace program sizes
# its own working sets from, so the two never promise the same byte twice): of what the server may use (the memory
# less LAPLACE_PG_RESERVED), a quarter is the shared cache, a quarter the backends' private memory, a quarter the
# client's (ingest, build, API) and a quarter the operating system's page cache. The private quarter reserves maintenance
# and every connection's temporary buffers, then budgets execution for active query leaders plus parallel workers.
# Idle connection capacity is not executor concurrency. PostgreSQL's own guidance: 25% of memory for shared_buffers and no
# more than 40%; work_mem is spent by every sort and hash of every backend at once; maintenance_work_mem is taken by
# every autovacuum worker unless autovacuum_work_mem bounds it (runtime-config-resource, 18).
#
# The log's bound is the volume it is on. max_wal_size is the checkpoint target, not a directory quota: the log runs
# past it while a checkpoint catches up, and a target equal to the volume filled it and stopped the server. Half of a
# dedicated volume leaves a reserve the size of the target (2026-10-03: the three-eighths target, 24 GB, checkpointed
# from WAL 35 times and from the timer never; 170 GB and 36 million full-page images in an evening). A log that shares
# its volume with the data is bounded at a quarter of it, 32 GB at most, so the host keeps room for the data.
# wal_compression zstd: on 23,450 of ConceptNet's B-tree images, level 3 wrote 3,781 bytes a page against lz4's 4,711,
# at 57 us a page against 17. wal_level minimal: nothing reads this server's log but its own crash recovery (no
# standby, no slot, no archive); a table made or truncated in a transaction is written without WAL and synced at
# commit, which is how laplace merge rewrites a leaf partition. PostgreSQL will not start at minimal unless
# max_wal_senders is 0. Asynchronous reads go through io_workers (io_method worker; io_uring cancelled reads mid-query
# on the 5.15 kernel, every month of logs since 2026-08-16); the pool is the real ceiling of in-flight reads, so
# effective_io_concurrency follows it (above the pool it bought nothing: 3,175 ms against 3,167 ms on a cold 2.5 GB
# leaf, 2026-08-16). The partitioned substrate locks hundreds of leaves, indexes and toast tables in one transaction;
# max_locks_per_transaction sizes a shared table of that many slots per allowed connection.
set -euo pipefail
_tune_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -n "${LAPLACE_PGDATA:-}" ] || . "$_tune_here/laplace.env"
# A workflow that exports an empty LAPLACE_CONNINFO must still get this file's default.
# ${VAR:-default} does not fill an empty string.
if [ -z "${LAPLACE_CONNINFO:-}" ]; then
  LAPLACE_CONNINFO="host=/tmp port=5432 user=${LAPLACE_ROLE:-laplace} dbname=laplace"
fi
PROFILE=${LAPLACE_PG_PROFILE:-substrate}
[[ "$PROFILE" != knowledge ]] || PROFILE=substrate
case $PROFILE in substrate|app) ;; *) echo "tune-pg: LAPLACE_PG_PROFILE is substrate or app, not '$PROFILE'" >&2; exit 2 ;; esac
PGDATA=${TUNE_PGDATA:-$LAPLACE_PGDATA}
PGWAL=${PGWAL:-$LAPLACE_PGWAL}
PGBIN=${PGBIN:-$LAPLACE_PG_DIR/bin}
PGUSER=${PGUSER:-$LAPLACE_PGUSER}
SERVICE=${SERVICE:-$LAPLACE_PGSERVICE}
TUNE_SOCKET=${TUNE_SOCKET:-/tmp}      # where root reaches the server as its own user (the application cluster: /var/run/postgresql)
TUNE_CONN=${TUNE_CONN:-$(printf '%s' "$LAPLACE_CONNINFO" | sed 's/dbname=[^ ]*/dbname=postgres/')}
case $TUNE_CONN in *dbname=*) ;; *) TUNE_CONN="$TUNE_CONN dbname=postgres" ;; esac
TUNE_PORT=$(printf '%s' "$TUNE_CONN" | sed -n 's/.*port=\([0-9]*\).*/\1/p'); TUNE_PORT=${TUNE_PORT:-5432}
TUNE_HOST=$(printf '%s' "$TUNE_CONN" | sed -n 's/.*host=\([^ ]*\).*/\1/p')

# ---------------------------------------------------------------------------------------------------- the facts
# Each read from this machine; TUNE_FACT_* names one instead (--plan for another machine, and the tests).
to_kb() {  # a size with a unit (34GB, 512MB, 1048576kB, 4096) in kB
  local v=${1// /}; case $v in
    *GB|*gb|*G|*g) echo $(( ${v%%[GgBb]*} * 1048576 )) ;;
    *MB|*mb|*M|*m) echo $(( ${v%%[MmBb]*} * 1024 )) ;;
    *kB|*KB|*kb|*K|*k) echo "${v%%[KkBb]*}" ;;
    *TB|*tb|*T|*t) echo $(( ${v%%[TtBb]*} * 1073741824 )) ;;
    *[0-9]) echo "$v" ;;
    *) echo "tune-pg: not a size: '$1'" >&2; return 1 ;;
  esac
}
fact_ram_kb() {
  [ -z "${TUNE_FACT_RAM_KB:-}" ] || { echo "$TUNE_FACT_RAM_KB"; return; }
  local kb lim; kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  # a container or WSL distribution bounded by its cgroup has that much, whatever the machine has
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ -r "$f" ] || continue; lim=$(cat "$f"); case $lim in max|'') continue ;; esac
    [ "$((lim / 1024))" -lt "$kb" ] && kb=$((lim / 1024)); break
  done
  echo "$kb"
}
# nproc reports OMP_NUM_THREADS when a shell has set it
fact_threads() { [ -z "${TUNE_FACT_THREADS:-}" ] || { echo "$TUNE_FACT_THREADS"; return; }; env -u OMP_NUM_THREADS -u MKL_NUM_THREADS nproc; }
fact_cores() {  # the physical cores: one per distinct set of sibling threads
  [ -z "${TUNE_FACT_CORES:-}" ] || { echo "$TUNE_FACT_CORES"; return; }
  local n
  n=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/core_cpus_list 2>/dev/null | sort -u | wc -l)
  [ "$n" -gt 0 ] || n=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list 2>/dev/null | sort -u | wc -l)
  [ "$n" -gt 0 ] || n=$(fact_threads)
  echo "$n"
}
# the block device under a path, by major:minor through the mount table and sysfs: a loop file, a bind mount, a
# mapper device or a root the table names /dev/root all resolve, and nothing stats a directory the role cannot read
mount_of() {  # $1 path -> "maj:min mountpoint"; optional mount table for detector tests
  local path=$1 table=${2:-/proc/self/mountinfo} id parent dev root mp rest best_dev='' best_mp='' l=0
  [[ "$path" = /* ]] || { echo 'tune-pg: mount path must be absolute' >&2; return 1; }
  while IFS=' ' read -r id parent dev root mp rest; do
    # mountinfo encodes spaces, tabs, newlines and backslashes as octal escapes.
    printf -v mp '%b' "$mp"
    case $path in "$mp"|"$mp"/*) ;; *) [ "$mp" = / ] || continue ;; esac
    if [ ${#mp} -ge "$l" ]; then l=${#mp}; best_dev=$dev; best_mp=$mp; fi
  done < "$table"
  [ -n "$best_dev" ] && printf '%s %s\n' "$best_dev" "$best_mp"
}
fact_rotational() {  # does the data's device rotate: through dm/loop/md to the disks beneath, any that rotates
  [ -z "${TUNE_FACT_ROTATIONAL:-}" ] || { echo "$TUNE_FACT_ROTATIONAL"; return; }
  local dev d q rot=0 seen
  set -- $(mount_of "$PGDATA" 2>/dev/null || echo ""); dev=${1:-}
  [ -n "$dev" ] && [ -d "/sys/dev/block/$dev" ] || { echo 0; return; }
  seen="/sys/dev/block/$dev"; q="$seen/queue/rotational"
  while [ -n "$seen" ]; do
    set -- $seen; d=$1; seen=${seen#"$d"}; seen=${seen# }
    [ -d "$d/slaves" ] && [ -n "$(ls "$d/slaves" 2>/dev/null)" ] && { for s in "$d"/slaves/*; do seen="$seen /sys/class/block/$(basename "$s")"; done; continue; }
    [ -f "$d/../queue/rotational" ] && q="$d/../queue/rotational" || q="$d/queue/rotational"
    [ -r "$q" ] && [ "$(cat "$q")" = 1 ] && rot=1
  done
  echo $rot
}
fact_wal_bytes() {  # the volume the log is on, and whether the log has it to itself: "bytes shared"
  [ -z "${TUNE_FACT_WAL_BYTES:-}" ] || { echo "$TUNE_FACT_WAL_BYTES ${TUNE_FACT_WAL_SHARED:-0}"; return; }
  local dev mp bytes shared
  local mount; mount=$(mount_of "$PGWAL") || return 1
  dev=${mount%% *}; mp=${mount#* }
  [ -n "$dev" ] || { echo "tune-pg: no mount holds $PGWAL" >&2; return 1; }
  [ -r "/sys/dev/block/$dev/size" ] || { echo "tune-pg: device $dev of $PGWAL has no size in sysfs" >&2; return 1; }
  bytes=$(( $(cat "/sys/dev/block/$dev/size") * 512 ))
  if [ "$mp" = "$PGWAL" ]; then shared=0; else shared=1; fi
  echo "$bytes $shared"
}
fact_reserved_kb() { to_kb "${LAPLACE_PG_RESERVED:-0}"; }
fact_buffers_max_kb() { [ -n "${LAPLACE_PG_BUFFERS_MAX:-}" ] && to_kb "$LAPLACE_PG_BUFFERS_MAX" || echo 0; }
# the server is tuned from the machine that runs it: a client host (hart-prod's LAPLACE_CONNINFO names hart-cloud's
# server) would hand it its own memory and cores
tune_local_or_die() {
  case ${TUNE_HOST:-} in ''|/*|localhost|127.*|::1) return 0 ;; esac
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$TUNE_HOST" && return 0
  [ "$TUNE_HOST" = "$(hostname)" ] || [ "$TUNE_HOST" = "$(hostname -f 2>/dev/null)" ] && return 0
  echo "tune-pg: $TUNE_HOST is not this machine: a server is tuned on the host that runs it (its memory, its cores, its volumes), not from a client" >&2
  return 1
}

# ---------------------------------------------------------------------------------------------------- the rules
max() { [ "$1" -gt "$2" ] && echo "$1" || echo "$2"; }
min() { [ "$1" -lt "$2" ] && echo "$1" || echo "$2"; }
clamp() { min "$(max "$1" "$2")" "$3"; }   # value lo hi
plan() {  # every derived quantity as NAME=value lines; declared() formats them
  local ram_kb threads cores reserved_kb usable_kb cap_kb rotational wal shared wal_bytes
  local shared_kb ecs_kb private_kb maint_dom_kb exec_kb wal_mb min_wal_mb wal_buf_kb
  local par gather avw iow mwp ingest serving reserved_conns conns active backends work_kb temp_kb temp_total_kb mwm_kb avwm_kb eic rpc locks over_kb
  ram_kb=$(fact_ram_kb); threads=$(fact_threads); cores=$(fact_cores); reserved_kb=$(fact_reserved_kb); cap_kb=$(fact_buffers_max_kb)
  rotational=$(fact_rotational); set -- $(fact_wal_bytes); wal_bytes=$1; shared=$2
  [ "$cores" -ge 1 ] || cores=1; [ "$threads" -ge "$cores" ] || threads=$cores
  # what the server may use: the memory less what others keep, never less than an eighth of it
  usable_kb=$(max $((ram_kb - reserved_kb)) $((ram_kb / 8)))
  shared_kb=$((usable_kb / 4)); [ "$cap_kb" -gt 0 ] && shared_kb=$(min "$shared_kb" "$cap_kb"); shared_kb=$(max "$shared_kb" 131072)
  ecs_kb=$((usable_kb * 7 / 10))
  private_kb=$((usable_kb / 4))
  # the log: half of its own volume, a quarter of a shared one and 32 GB at most, a gigabyte at least
  if [ "$shared" = 1 ]; then wal_mb=$(min $((wal_bytes / 1048576 / 4)) 32768); else wal_mb=$((wal_bytes / 1048576 / 2)); fi
  wal_mb=$(max "$wal_mb" 1024)
  min_wal_mb=$(clamp $((wal_mb / 8)) 80 4096)
  wal_buf_kb=$(clamp $((shared_kb / 32)) 16384 $((wal_mb * 1024 / 16)))
  # the processors: parallel query on the cores (a sibling thread is not another core), asynchronous reads on the threads
  par=$cores; gather=$((cores / 2)); avw=$(max 3 $((cores / 2))); iow=$(clamp $((threads * 2 / 3)) 1 32); mwp=$((par + 4))
  # the connection plan: who may be connected at once. substrate: the ingest's fan (one coordinator, two a core, three
  # observers: the monorepo's measured population), the serving pools, the maintenance workers; app: the serving pools
  # and the maintenance workers. The serving pools are the host's services' (the API, the MCP, the runners' checks, a
  # person's psql), which the machine cannot say: LAPLACE_PG_SERVING declares them with the measurement; undeclared,
  # four a thread (on hart-server one MCP process held 13 idle backends after a single search, 2026-10-10 01:07Z, so
  # one a thread was too few). Three superuser connections are reserved.
  case $PROFILE in
    substrate) ingest=$((1 + 2 * cores + 3)); serving=${LAPLACE_PG_SERVING:-$((4 * threads))}; locks=1024 ;;
    app)       ingest=0; serving=${LAPLACE_PG_SERVING:-$(max 16 $((8 * threads)))}; locks=64 ;;
  esac
  [[ "$serving" =~ ^(0|[1-9][0-9]{0,5})$ ]] || { echo 'tune-pg: LAPLACE_PG_SERVING must be a nonnegative integer (at most six digits)' >&2; return 1; }
  reserved_conns=3; conns=$((ingest + serving + avw + reserved_conns))
  active=${LAPLACE_PG_ACTIVE_QUERIES:-$(min "$cores" "$((conns - reserved_conns))")}
  [[ "$active" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$active" -le "$((conns - reserved_conns))" ] || {
    echo 'tune-pg: LAPLACE_PG_ACTIVE_QUERIES must be positive and fit non-reserved connection capacity' >&2; return 1;
  }
  # Connection slots are capacity, not busy executors. Keep their full temporary-buffer
  # allowance, but do not allocate half the executor budget to unused temp tables.
  maint_dom_kb=$((private_kb / 4)); mwm_kb=$(max $((maint_dom_kb / 2)) 65536); avwm_kb=$(max $((maint_dom_kb / 2 / avw)) 1024)
  temp_kb=8192; temp_total_kb=$((conns * temp_kb))
  exec_kb=$((private_kb - mwm_kb - avw * avwm_kb - temp_total_kb)); backends=$((active + par))
  local work_nodes=${LAPLACE_PG_WORK_NODES:-2}
  [[ "$work_nodes" =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'tune-pg: LAPLACE_PG_WORK_NODES must be a positive integer (at most six digits)' >&2; return 1; }
  # work_mem applies to each simultaneous sort/hash node, not once per connection.
  # This declared population is a workload estimate; arbitrary SQL is not memory-bounded by it.
  work_kb=$(max $((exec_kb / backends / work_nodes)) 4096)
  # the floors (work_mem 4 MB, temp_buffers 8 MB, maintenance 64 MB, autovacuum 1 MB) are PostgreSQL's useful minimums;
  # when the declared connections at their floors want more than the private quarter, the host is over-committed by
  # its declarations, and the plan says by how much rather than promising what is not there
  over_kb=$(( backends * work_nodes * work_kb + temp_total_kb + mwm_kb + avw * avwm_kb - private_kb )); [ "$over_kb" -gt 0 ] || over_kb=0
  if [ "$rotational" = 1 ]; then eic=2; rpc=4; else eic=$iow; rpc=1.1; fi
  cat <<PLAN
fact.memory_kb=$ram_kb
fact.reserved_kb=$reserved_kb
fact.threads=$threads
fact.cores=$cores
fact.wal_volume_bytes=$wal_bytes
fact.wal_volume_shared=$shared
fact.data_rotational=$rotational
fact.profile=$PROFILE
usable_kb=$usable_kb
shared_kb=$shared_kb
ecs_kb=$ecs_kb
private_kb=$private_kb
wal_mb=$wal_mb
min_wal_mb=$min_wal_mb
wal_buf_kb=$wal_buf_kb
par=$par
gather=$gather
avw=$avw
iow=$iow
mwp=$mwp
conns=$conns
active_queries=$active
backends=$backends
temp_total_kb=$temp_total_kb
exec_kb=$exec_kb
mwm_kb=$mwm_kb
avwm_kb=$avwm_kb
work_kb=$work_kb
work_nodes=$work_nodes
temp_kb=$temp_kb
eic=$eic
rpc=$rpc
locks=$locks
over_kb=$over_kb
PLAN
}
mb() { echo "$(( $1 / 1024 ))MB"; }   # kB -> whole MB (every value here is a multiple of 8 kB blocks)
declared() {
  local plan; plan=$(plan) || return 1; v(){ sed -n "s/^$1=//p" <<<"$plan"; }
  local wal_level=minimal wal_senders=0
  if [[ "$PROFILE" == app ]]; then wal_level=replica; wal_senders=3; fi
  local trace=${LAPLACE_PG_TRACE:-full}
  local pgss_track=all io_timing=on
  case "$trace" in
    full)    pgss_track=all;  io_timing=on ;;
    reduced) pgss_track=top;  io_timing=on ;;
    off)     pgss_track=none; io_timing=off ;;
    *) echo "tune-pg: LAPLACE_PG_TRACE must be full, reduced, or off (got '$trace')" >&2; return 1 ;;
  esac
  # Plan output expands array constants on every partition; parameter limits do
  # not bound it. Diagnostic sessions can opt in without enabling global dumps.
  cat <<SET
wal_level                        $wal_level
max_wal_senders                  $wal_senders
shared_buffers                   $(mb "$(v shared_kb)")
effective_cache_size             $(mb "$(v ecs_kb)")
work_mem                         $(mb "$(v work_kb)")
maintenance_work_mem             $(mb "$(v mwm_kb)")
autovacuum_work_mem              $(mb "$(v avwm_kb)")
temp_buffers                     $(mb "$(v temp_kb)")
hash_mem_multiplier              1.0
huge_pages                       try
io_method                        worker
io_workers                       $(v iow)
effective_io_concurrency         $(v eic)
maintenance_io_concurrency       $(v eic)
random_page_cost                 $(v rpc)
default_toast_compression        lz4
max_wal_size                     $(v wal_mb)MB
max_slot_wal_keep_size           $(v wal_mb)MB
min_wal_size                     $(v min_wal_mb)MB
wal_buffers                      $(mb "$(v wal_buf_kb)")
wal_compression                  zstd
checkpoint_timeout               60min
checkpoint_completion_target     0.9
bgwriter_lru_maxpages            1000
max_worker_processes             $(v mwp)
max_parallel_workers             $(v par)
max_parallel_workers_per_gather  $(v gather)
max_parallel_maintenance_workers $(v gather)
jit                              off
enable_parallel_append           on
gin_pending_list_limit           32MB
autovacuum_max_workers           $(v avw)
autovacuum_naptime               10s
autovacuum_vacuum_cost_delay     0
autovacuum_vacuum_cost_limit     2000
autovacuum_vacuum_scale_factor   0.05
autovacuum_analyze_scale_factor  0.02
autovacuum_vacuum_insert_scale_factor 0.01
max_locks_per_transaction        $(v locks)
shared_preload_libraries         pg_stat_statements,auto_explain
pg_stat_statements.track         $pgss_track
auto_explain.log_min_duration    -1
auto_explain.log_parameter_max_length 0
track_io_timing                  $io_timing
track_wal_io_timing              $io_timing
listen_addresses                 *
ssl                              on
port                             $TUNE_PORT
max_connections                  $(v conns)
superuser_reserved_connections   3
max_prepared_transactions        0
SET
  [ "$PROFILE" = substrate ] && echo "temp_tablespaces                 pgtemp"
  return 0
}

tune_plan() {
  local p; p=$(plan) || return 1
  echo "tune-pg: the facts of $(hostname) for the $PROFILE profile"
  sed -n 's/^fact\.//p' <<<"$p" | awk -F= '{printf "  %-24s %s\n", $1, $2}'
  echo 'tune-pg: workload budget (estimated concurrency, not query admission control)'
  awk -F= '$1 ~ /^(conns|active_queries|par|backends|work_nodes|temp_total_kb|exec_kb|over_kb)$/ {printf "  %-24s %s\n", $1, $2}' <<<"$p"
  echo "tune-pg: the settings they give"
  declared | awk '{printf "  %-40s %s\n", $1, $2}'
  local over; over=$(sed -n 's/^over_kb=//p' <<<"$p")
  [ "$over" = 0 ] || echo "tune-pg: OVER-COMMITTED by $((over / 1024)) MB: the connections declared, at PostgreSQL's floors, want more than the backends' quarter; fewer serving connections (LAPLACE_PG_SERVING) or more memory for the server (LAPLACE_PG_RESERVED)" >&2
}

# This rejects the planner's own known overcommit; it is not a bound on every
# query operator or every other service's memory. Those need workload evidence.
tune_validate_plan() {
  local p over
  p=$(plan) || return 1
  over=$(sed -n 's/^over_kb=//p' <<<"$p")
  [[ "$over" =~ ^[0-9]+$ ]] || { echo 'tune-pg: invalid memory plan' >&2; return 1; }
  if [ "$over" -gt 0 ]; then
    echo "tune-pg: OVER-COMMITTED by $over kB; refusing database changes. Reconcile the declared resident memory and serving connections before applying." >&2
    return 1
  fi
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
    out=$(su "$PGUSER" -c "$PGBIN/psql -X -h $TUNE_SOCKET -p $TUNE_PORT -d postgres -v ON_ERROR_STOP=1 -At -F '|' -f $f" </dev/null) && rc=0 || rc=$?
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
  local name value match context source pending live literal n=0
  tune_validate_plan || return 1
  tune_local_or_die
  while read -r name value; do [ -n "$name" ] && want[$name]=$value; done < <(declared)
  while IFS='|' read -r name match context source pending live; do
    [ -n "$name" ] || continue
    # Already the declared value and already recorded, or a postmaster knob already in force:
    # writing that again can mark a restart for a value the server is already running.
    if [ "$match" = t ] && { [ "$source" = "configuration file" ] || [ "$context" = postmaster ]; }; then
      continue
    fi
    value=${want[$name]}
    # A list parameter takes its items as separate literals. One literal holding commas is one
    # item: shared_preload_libraries = 'a,b' is written as '"a,b"' and the server then looks for a
    # library called a,b and does not start.
    case $name in
      shared_preload_libraries|session_preload_libraries|local_preload_libraries|search_path|temp_tablespaces|log_destination|synchronous_standby_names|unix_socket_directories|listen_addresses|wal_consistency_checking)
        literal=$(printf '%s' "$value" | awk -F, '{for (i = 1; i <= NF; i++) {gsub(/^ +| +$/, "", $i); gsub(/\x27/, "\x27\x27", $i); printf "%s\x27%s\x27", (i > 1 ? ", " : ""), $i}}') ;;
      *) literal="'${value//\'/\'\'}'" ;;
    esac
    if ! tune_psql "ALTER SYSTEM SET $name = $literal" >/dev/null; then
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
  local began; began=$(tune_psql "SELECT pg_postmaster_start_time()")
  if [ "$(id -u)" = 0 ]; then
    systemctl restart "$unit"
  elif [ -w "$LAPLACE_LOCKS" ] && systemctl is-active -q laplace-pg-restart.path; then
    # the runner has no root: it asks, and root's laplace-pg-restart.service restarts the unit
    # (setup.sh rights), never while an ingest holds its lock
    date -u +%FT%TZ > "$LAPLACE_LOCKS/restart-pg"
  else
    echo "tune-pg: $pending pending_restart; $unit was not restarted (sudo ./setup.sh rights installs the restart the runner may ask for)" >&2
    return 1
  fi
  # restarted when the server answers with a start time later than the one it had
  for i in $(seq 180); do
    sleep 1
    now=$(tune_psql "SELECT pg_postmaster_start_time()" 2>/dev/null) || continue
    [ -n "$now" ] && [ "$now" != "$began" ] && { echo "tune-pg: $unit restarted for $pending"; return 0; }
  done
  echo "tune-pg: $unit was not restarted within 180 s (journalctl -u laplace-pg-restart.service)" >&2
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
    --check) tune_validate_plan && tune_check ;;
    --plan) tune_plan; tune_validate_plan ;;
    "") tune_apply; tune_restart; tune_check ;;
    *) echo "usage: tune-pg.sh [--check|--plan]" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  tune_main "${1:-}"
fi
