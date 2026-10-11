#!/usr/bin/env bash
# Shared default and explicit setup ordering. Stage implementations live in setup.sh.
# Call as a simple command under set -e: conditional calls disable Bash errexit.
setup_dispatch() {
  local p
  local -a parts=("$@")
  ((${#parts[@]})) || parts=(all)
  for p in "${parts[@]}"; do
    case $p in
      all|drop|rights|volumes|packages|kernel|deps|cluster|settings|access|appdb|backup|site|runtime|modular|agents|idlestop|report|chess|shares|landing|secrets-stack|secrets-backup|secrets-client|knowledge-client) ;;
      *) echo "Unknown setup stage: $p" >&2; return 2 ;;
    esac
  done
  for p in "${parts[@]}"; do
    case $p in
      all)
        volumes; packages; rights; kernel; deps; cluster; settings; access; appdb; backup
        landing_of_all=1; landing; landing_of_all=
        site; runtime; modular; agents; idlestop; report
        ;;
      *) "$p" ;;
    esac
  done
}

modular() {
  part 'modular runtime'
  python3 "$here/installation/modular.py" install
}

runtime() {
  part 'application runtime'
  if [[ -z $setup_runtime_manifest ]]; then
    say 'runtime' 'no runtime installation declared for this host'
    return 0
  fi
  python3 "$here/installation/runtime.py" --manifest "$setup_runtime_manifest"
  setup_runtime_verified=1
}

appdb() {
  part 'application database'
  if [[ -n $setup_runtime_manifest ]]; then
    say 'application database' 'uses the runtime declaration and existing configured PostgreSQL cluster'
    return 0
  fi
  appdb_cluster
}
