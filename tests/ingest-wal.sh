#!/bin/bash
# An idle or fully expired interval never reaches pg_walinspect; other failures retain their actual cause.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
log=$(mktemp -d)
trap 'rm -rf "$log"' EXIT
eval "$(sed -n '/^wal_read(){/,/^# The log is written/{ /^# The log is written/d; p; }' "$here/ingest.sh")"
wal_oldest='SELECT oldest_retained_lsn'
bound=1/100
inspect=ok
sql(){
  case "$1" in
    *'SELECT start_lsn'*) printf '%s' "$bound" ;;
    *pg_get_wal_block_info*)
      if [ "$inspect" = fail ]; then echo 'ERROR: permission denied for function pg_get_wal_block_info' >&2; return 1; fi
      printf 'actual sample\n' ;;
    *) echo "unexpected SQL: $1" >&2; return 1 ;;
  esac
}
# SQL itself must not be called at the end of written WAL.
inspect=fail
wal_read 1/100 1/100 2>"$log/idle.err"
[ ! -s "$log/idle.err" ] && [ ! -e "$log/wal.tsv" ]
# Clamping to the oldest retained segment can leave no readable interval.
bound=
wal_read 0/2000 0/3000 2>"$log/expired.err"
[ ! -s "$log/expired.err" ] && [ ! -e "$log/wal.tsv" ]
bound=1/100
inspect=ok
wal_read 1/100 1/200 2>"$log/live.err"
[ ! -s "$log/live.err" ] && grep -q 'actual sample' "$log/wal.tsv"
inspect=fail
wal_read 1/100 1/200 2>"$log/error.err"
grep -q 'permission denied' "$log/error.err"
grep -q 'WAL sample from 1/100 to 1/200 failed' "$log/error.err"
! grep -q 'recycled before' "$log/error.err"
echo 'ingest-wal: empty intervals skipped; real sample and actual error retained'
