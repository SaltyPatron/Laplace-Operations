#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?build scratch required}"
work=$(mktemp -d "$TMPDIR/operation-lock.XXXXXX")
trap 'rm -rf "$work"' EXIT
export LAPLACE_LOCKS=$work LOCK_HELPER=$root/operation-lock.sh
export LAPLACE_HOST_LOCK_WAIT_SECONDS=0
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

# An independent waiter must remain outside the mutation boundary while held,
# then acquire after release without an operator rerunning the command.
laplace_host_lock exclusive
export LOCK_TEST_WORK=$work
LAPLACE_HOST_LOCK_WAIT_SECONDS=5 bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive && touch "$LOCK_TEST_WORK/acquired"' 8>&- 2>"$work/waiting" &
waiter=$!
for attempt in {1..50}; do grep -q 'Waiting up to' "$work/waiting" && break; sleep .02; done
grep -q 'Waiting up to' "$work/waiting"
[[ ! -e "$work/acquired" ]]
flock -u 8
wait "$waiter"
[[ -e "$work/acquired" ]]
echo 'PASS independent deployment waits for release and then continues'

laplace_host_lock exclusive
rc=0
LAPLACE_HOST_LOCK_WAIT_SECONDS=1 bash -c '. "$LOCK_HELPER"; laplace_host_lock shared && touch "$LOCK_TEST_WORK/incorrect"' 8>&- >/dev/null 2>&1 || rc=$?
[[ $rc == 3 && ! -e "$work/incorrect" ]]
echo 'PASS expired wait performs no protected operation'
for invalid in -1 bad 1.5; do
  rc=0
  LAPLACE_HOST_LOCK_WAIT_SECONDS=$invalid bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive' 8>&- >/dev/null 2>&1 || rc=$?
  [[ $rc == 2 ]]
done
flock -u 8
echo 'PASS invalid wait declarations are rejected'

# Writer preference: while a deployment waits for an ingest to finish, a later ingest waits behind it rather than
# being granted past it (flock alone grants it, and a stream of them would hold the deployment off until its deadline).
laplace_host_lock shared
LAPLACE_HOST_LOCK_WAIT_SECONDS=10 bash -c '. "$LOCK_HELPER"; laplace_host_lock exclusive && touch "$LOCK_TEST_WORK/deployed"; sleep 1' 8>&- 2>"$work/deploy-waiting" &
deployment=$!
for attempt in {1..100}; do grep -q 'Waiting up to' "$work/deploy-waiting" && break; sleep .02; done
grep -q 'Waiting up to' "$work/deploy-waiting"
rc=0; bash -c '. "$LOCK_HELPER"; laplace_host_lock shared && touch "$LOCK_TEST_WORK/barged"' 8>&- >/dev/null 2>&1 || rc=$?
[[ $rc == 3 && ! -e "$work/barged" ]]
LAPLACE_HOST_LOCK_WAIT_SECONDS=10 bash -c '. "$LOCK_HELPER"; laplace_host_lock shared && { [[ -e "$LOCK_TEST_WORK/deployed" ]] && touch "$LOCK_TEST_WORK/after"; }' 8>&- 2>/dev/null &
later=$!
sleep .3
[[ ! -e "$work/deployed" ]]
# the ingest's own nested command inherits its lock and does not queue behind the deployment it holds off
LAPLACE_HOST_LOCK_WAIT_SECONDS=0 bash -c '. "$LOCK_HELPER"; laplace_host_lock shared'
flock -u 8
wait "$deployment"
wait "$later"
[[ -e "$work/deployed" && -e "$work/after" ]]
echo 'PASS a waiting deployment is not overtaken by a later ingest; that ingest runs after it; a nested command of the holder does not queue'
