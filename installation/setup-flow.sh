#!/usr/bin/env bash
# Shared default and explicit setup ordering. Stage implementations live in setup.sh.
# Call as a simple command under set -e: conditional calls disable Bash errexit.
setup_dispatch() {
  local p
  local -a parts=("$@")
  ((${#parts[@]})) || parts=(all)
  for p in "${parts[@]}"; do
    case $p in
      all|drop|rights|volumes|packages|kernel|deps|cluster|postgres|restart-controller|settings|access|appdb|backup|site|runtime|modular|agents|shared|locks|logging|idlestop|report|chess|shares|landing|secrets-stack|secrets-backup|secrets-client|database-client) ;;
      *) echo "Unknown setup stage: $p" >&2; return 2 ;;
    esac
  done
  for p in "${parts[@]}"; do
    case $p in
      all)
        volumes; packages; rights; kernel; deps; cluster; postgres; restart-controller; settings; access; appdb; backup
        landing_of_all=1; landing; landing_of_all=
        configured_secrets
        modular; agents; idlestop; report
        ;;
      *) "$p" ;;
    esac
  done
}

configured_secrets() {
  if [[ -f /etc/laplace/secrets-protection.json ]]; then
    bash "$here/secrets/recover.sh"
    python3 "$here/secrets/protection.py" --configuration /etc/laplace/secrets-protection.json
  fi
}

postgres() {
  part 'PostgreSQL installation'
  python3 "$here/installation/postgres-installation.py"
}

restart-controller() {
  part 'PostgreSQL restart controller'
  python3 "$here/installation/database-restart.py" --environment --install
}

modular() {
  part 'modular runtime'
  python3 "$here/installation/modular.py" install
}

runtime() {
  part 'monorepo runtime (compatibility entry point)'
  python3 "$here/installation/runtime.py"
  setup_runtime_verified=1
}

appdb() {
  part 'application database'
  if [[ -z ${LAPLACE_APP_DBNAME:-} ]]; then
    say 'application database' 'none declared; database consumers use the existing cluster'
    return 0
  fi
  appdb_cluster
}
