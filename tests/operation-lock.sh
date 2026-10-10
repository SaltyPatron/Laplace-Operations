#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?build scratch required}"
work=$(mktemp -d "$TMPDIR/operation-lock.XXXXXX")
trap 'rm -rf "$work"' EXIT
export LAPLACE_LOCKS=$work LOCK_HELPER=$root/operation-lock.sh
# Holder remains this shell; candidates explicitly close descriptor 8 so they
# represent independent processes rather than nested commands sharing our lock.
. "$LOCK_HELPER"
laplace_host_lock shared
bash -c '. "$LOCK_HELPER"; laplace_host_lock shared' 8>&-
rc=0; bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive' 8>&- >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]]
echo 'PASS active ingestion permits another reader but blocks deployment'
flock -u 8
laplace_host_lock exclusive
for mode in shared exclusive; do
  rc=0; bash -c '. "$LOCK_HELPER"; laplace_host_lock "$1"' _ "$mode" 8>&- >/dev/null 2>&1 || rc=$?
  [[ $rc == 3 ]]
done
echo 'PASS deployment blocks ingestion and another deployment'
bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive'
echo 'PASS nested installer inherits the held lock without deadlocking'
# A nested command ending does not release the parent's descriptor.
rc=0; bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive' 8>&- >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]]
flock -u 8
bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive' 8>&-
echo 'PASS release permits the next operation; lock file is retained'
[[ -f "$work/host-resource.lock" ]]
