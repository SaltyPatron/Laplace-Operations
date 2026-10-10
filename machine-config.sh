#!/usr/bin/env bash
# Public host declarations and private credentials share a traversable directory.
machine_config_permissions() {
  local directory=${1:-/etc/laplace}
  install -d -m 755 "$directory"
  if [[ -f "$directory/machine.env" ]]; then
    chmod 644 "$directory/machine.env"
  fi
}
