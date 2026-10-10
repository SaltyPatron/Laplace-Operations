#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export LAPLACE_PGDATA=/fixture/data LAPLACE_PGWAL=/fixture/wal LAPLACE_PG_DIR=/unused
export LAPLACE_PGUSER=postgres LAPLACE_PGSERVICE=pgdata LAPLACE_CONNINFO='host=/tmp dbname=postgres'
export TUNE_FACT_RAM_KB=50037756 TUNE_FACT_THREADS=32 TUNE_FACT_CORES=24
export TUNE_FACT_WAL_BYTES=2000381014016 TUNE_FACT_WAL_SHARED=1 TUNE_FACT_ROTATIONAL=0
export LAPLACE_PG_RESERVED=34GB LAPLACE_PG_BUFFERS_MAX=1GB
unset LAPLACE_PG_SERVING LAPLACE_PG_PROFILE
. "$here/tune-pg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tune_local_or_die() { :; }
tune_psql() { touch "$work/database-touched"; }
if tune_apply >"$work/output" 2>&1; then
  echo 'overcommitted plan was accepted' >&2; exit 1
fi
grep -q 'OVER-COMMITTED' "$work/output"
[ ! -e "$work/database-touched" ] || { echo 'overcommitted plan reached database access' >&2; exit 1; }
export TUNE_FACT_RAM_KB=131799160 TUNE_FACT_THREADS=12 TUNE_FACT_CORES=6 LAPLACE_PG_RESERVED=0
unset LAPLACE_PG_BUFFERS_MAX
tune_validate_plan
echo 'PostgreSQL overcommit refusal before database access: passed'
