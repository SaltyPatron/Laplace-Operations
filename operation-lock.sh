#!/bin/sh
# Cooperative host lock for shared runtime installation and active ingestion.
# File descriptor 8 is inherited by nested build/install commands. Never unlink it.
# Writer preference: the kernel's flock has none. A new shared holder is granted past a waiting exclusive one, so a
# stream of overlapping ingests and verifications could hold a deployment off until its deadline. So every
# acquisition, shared or exclusive, first passes a turnstile, the lock's path with .turnstile. It holds the turnstile
# exclusively only while it waits for the lock itself. A waiting deployment holds the turnstile, so no later reader gets
# in ahead of it; the readers already in drain, and then it has the lock. Every taker of the lock in shared mode must
# pass the turnstile the same way (installation/modular.py's host_lock does; the Engine's parity harness and the
# monorepo's site.sh are to). Descriptor 7 holds the turnstile and is closed before this returns.
laplace_host_lock_await() {
  if [ "$laplace_host_lock_wait" = wait ]; then
    flock "$1" "$2"
  else
    laplace_host_lock_left=$((laplace_host_lock_wait - ($(date +%s) - laplace_host_lock_start)))
    [ "$laplace_host_lock_left" -ge 0 ] || laplace_host_lock_left=0
    flock "$1" -w "$laplace_host_lock_left" "$2"
  fi
}
laplace_host_lock_notice() {
  if [ "$laplace_host_lock_wait" = wait ]; then
    echo "Waiting for $laplace_host_lock_path (${1:-exclusive})" >&2
  else
    echo "Waiting up to ${laplace_host_lock_wait}s for $laplace_host_lock_path (${1:-exclusive})" >&2
  fi
  laplace_host_lock_holders
}
if [ -z "${_laplace_hl_loaded:-}" ]; then
  _laplace_hl_loaded=1
  _laplace_hl_salty=${SALTY_SUITE_ROOT:-}
  if [ -z "$_laplace_hl_salty" ] && [ -n "${LAPLACE_SRC:-}" ]; then
    _laplace_hl_salty="$LAPLACE_SRC/Salty-Suite"
  fi
  if [ -z "$_laplace_hl_salty" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
    _laplace_hl_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "$_laplace_hl_dir/../Salty-Suite/host-lock/host-lock.sh" ]; then
      _laplace_hl_salty="$_laplace_hl_dir/../Salty-Suite"
    elif [ -f "$_laplace_hl_dir/Salty-Suite/host-lock/host-lock.sh" ]; then
      _laplace_hl_salty="$_laplace_hl_dir/Salty-Suite"
    fi
  fi
  if [ -n "$_laplace_hl_salty" ] && [ -f "$_laplace_hl_salty/host-lock/host-lock.sh" ]; then
    . "$_laplace_hl_salty/host-lock/host-lock.sh"
  fi
fi
# Who has the lock open: pid, start time and command line of every process with a descriptor on it (/proc/locks names
# the short-lived flock child, not the holder). Processes of accounts this one cannot inspect are counted, not named.
laplace_host_lock_holders() {
  if command -v host_lock_holders >/dev/null 2>&1; then
    host_lock_holders "$laplace_host_lock_path"
    return $?
  fi
  [ -d /proc/self/fd ] || return 0
  laplace_host_lock_seen=$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$laplace_host_lock_path" 2>/dev/null |
    cut -d/ -f3 | sort -un | grep -vx "$$")
  if [ -z "$laplace_host_lock_seen" ]; then
    echo "  holder not visible to $(id -un) (another account's process): ls -l /proc/*/fd as root, or laplace-ops runs" >&2
    return 0
  fi
  for laplace_host_lock_pid in $laplace_host_lock_seen; do
    # this waiter's own children inherit the descriptor; they are not holders
    [ "$(ps -o ppid= -p "$laplace_host_lock_pid" 2>/dev/null | tr -d ' ')" = "$$" ] && continue
    laplace_host_lock_who=$(ps -o lstart= -o args= -p "$laplace_host_lock_pid" 2>/dev/null | cut -c1-200)
    [ -n "$laplace_host_lock_who" ] && echo "  open in pid $laplace_host_lock_pid: $laplace_host_lock_who" >&2
  done
  return 0
}
laplace_host_lock() {
  laplace_host_lock_wait=${LAPLACE_HOST_LOCK_WAIT_SECONDS:-0}
  case $laplace_host_lock_wait in
    wait) ;;
    ''|*[!0-9]*) echo 'LAPLACE_HOST_LOCK_WAIT_SECONDS must be a nonnegative integer or wait' >&2; return 2 ;;
  esac
  laplace_host_lock_path=${LAPLACE_HOST_LOCK:-${LAPLACE_LOCKS:?machine lock directory required}/host-resource.lock}
  if command -v host_lock >/dev/null 2>&1; then
    LAPLACE_HOST_LOCK_PATH="$laplace_host_lock_path"
    host_lock "${1:-exclusive}" 8 "$laplace_host_lock_path" "$laplace_host_lock_wait"
    return $?
  fi
  [ -d "$(dirname "$laplace_host_lock_path")" ] || { echo "missing host lock directory: $laplace_host_lock_path" >&2; return 1; }
  laplace_host_lock_inherited=0
  if [ /proc/self/fd/8 -ef "$laplace_host_lock_path" ]; then
    laplace_host_lock_inherited=1
  else
    laplace_host_lock_umask=$(umask)
    umask 002
    exec 8>>"$laplace_host_lock_path"
    umask "$laplace_host_lock_umask"
  fi
  case ${1:-exclusive} in
    exclusive) laplace_host_lock_mode=-x ;;
    shared) laplace_host_lock_mode=-s ;;
    *) echo 'host lock mode must be shared or exclusive' >&2; return 2 ;;
  esac
  # A nested command of the holder: the descriptor it inherited holds the lock already (and a holder never waits at its
  # own turnstile behind a deployment that waits for it).
  if [ "$laplace_host_lock_inherited" = 1 ] && flock "$laplace_host_lock_mode" -n 8; then return 0; fi
  # Try once first so normal acquisitions remain quiet. CI queues until the
  # real holder releases; an interactive caller can declare a numeric deadline.
  laplace_host_lock_umask=$(umask)
  umask 002
  exec 7>>"$laplace_host_lock_path.turnstile"
  umask "$laplace_host_lock_umask"
  laplace_host_lock_start=$(date +%s)
  laplace_host_lock_said=0
  if ! flock -x -n 7; then
    laplace_host_lock_notice "${1:-exclusive}"
    laplace_host_lock_said=1
    laplace_host_lock_await -x 7 || {
      exec 7>&-
      echo "host lock not acquired: $laplace_host_lock_path; no shared-runtime changes performed" >&2; laplace_host_lock_holders
      return 3
    }
  fi
  if ! flock "$laplace_host_lock_mode" -n 8; then
    [ "$laplace_host_lock_said" = 1 ] || laplace_host_lock_notice "${1:-exclusive}"
    laplace_host_lock_await "$laplace_host_lock_mode" 8 || {
      exec 7>&-
      echo "host lock not acquired: $laplace_host_lock_path; no shared-runtime changes performed" >&2; laplace_host_lock_holders
      return 3
    }
  fi
  exec 7>&-
  return 0
}
