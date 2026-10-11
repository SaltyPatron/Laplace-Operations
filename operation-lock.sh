#!/bin/sh
# Cooperative host lock for shared runtime installation and active ingestion.
# File descriptor 8 is inherited by nested build/install commands. Never unlink it.
laplace_host_lock() {
  laplace_host_lock_wait=${LAPLACE_HOST_LOCK_WAIT_SECONDS:-0}
  case $laplace_host_lock_wait in
    ''|*[!0-9]*) echo 'LAPLACE_HOST_LOCK_WAIT_SECONDS must be a nonnegative integer' >&2; return 2 ;;
  esac
  laplace_host_lock_path=${LAPLACE_HOST_LOCK:-${LAPLACE_LOCKS:?machine lock directory required}/host-resource.lock}
  [ -d "$(dirname "$laplace_host_lock_path")" ] || { echo "missing host lock directory: $laplace_host_lock_path" >&2; return 1; }
  if ! [ /proc/self/fd/8 -ef "$laplace_host_lock_path" ]; then
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
  # Try once first so normal and inherited acquisitions remain quiet. CI declares
  # its queue deadline; an interactive caller can choose zero for immediate refusal.
  flock "$laplace_host_lock_mode" -n 8 && return 0
  echo "Waiting up to ${laplace_host_lock_wait}s for $laplace_host_lock_path (${1:-exclusive})" >&2
  flock "$laplace_host_lock_mode" -w "$laplace_host_lock_wait" 8 || {
    echo "host lock deadline expired: $laplace_host_lock_path; no shared-runtime changes performed" >&2
    return 3
  }
}
