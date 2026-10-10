#!/bin/bash
# Exercise storage detection, not just arithmetic with predeclared TUNE_FACT values.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export LAPLACE_PGDATA=/data/pgdata LAPLACE_PGWAL=/data/pgdata/pg_wal
export LAPLACE_PG_DIR=/unused LAPLACE_PGUSER=postgres LAPLACE_PGSERVICE=pgdata
export LAPLACE_CONNINFO='host=/tmp dbname=postgres'
. "$here/tune-pg.sh"
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'MOUNTS'
20 1 253:8 / / rw - ext4 /dev/root rw
21 20 253:2 / /data/pgdata rw - ext4 /dev/data rw
22 21 253:3 / /data/pgdata/pg_wal rw - ext4 /dev/wal rw
23 20 8:1 / /data/with\040space rw - ext4 /dev/space rw
24 20 0:20 / /run/docker/netns/example rw - nsfs nsfs rw
MOUNTS
expect_mount() {
  local actual; actual=$(mount_of "$1" "$fixture")
  [ "$actual" = "$2" ] || { printf 'mount of %s: expected %s, got %s\n' "$1" "$2" "$actual" >&2; exit 1; }
}
expect_mount /data/pgdata '253:2 /data/pgdata'
expect_mount /data/pgdata/base/1 '253:2 /data/pgdata'
expect_mount /data/pgdata/pg_wal '253:3 /data/pgdata/pg_wal'
expect_mount /data/pgdata/pg_wal/segment '253:3 /data/pgdata/pg_wal'
expect_mount /data/pgdata-other '253:8 /'
expect_mount '/data/with space/file' '8:1 /data/with space'
expect_mount /unrelated '253:8 /'
if mount_of relative "$fixture" >/dev/null 2>&1; then echo 'relative path accepted' >&2; exit 1; fi
echo 'tune-pg storage mount detection: passed'
