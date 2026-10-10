#!/bin/sh
# Cooperative host lock for shared runtime installation and active ingestion.
# File descriptor 8 is inherited by nested build/install commands. Never unlink it.
laplace_host_lock() {
  laplace_host_lock_path=${LAPLACE_HOST_LOCK:-${LAPLACE_LOCKS:?machine lock directory required}/host-resource.lock}
  [ -d "$(dirname "$laplace_host_lock_path")" ] || { echo "missing host lock directory: $laplace_host_lock_path" >&2; return 1; }
  if ! [ /proc/self/fd/8 -ef "$laplace_host_lock_path" ]; then
    laplace_host_lock_umask=$(umask)
    umask 002
    exec 8>>"$laplace_host_lock_path"
    umask "$laplace_host_lock_umask"
  fi
  case ${1:-exclusive} in
    exclusive) flock -xn 8 ;;
    shared) flock -sn 8 ;;
    *) echo 'host lock mode must be shared or exclusive' >&2; return 2 ;;
  esac || { echo "another operation holds $laplace_host_lock_path; no shared-runtime changes performed" >&2; return 3; }
}
