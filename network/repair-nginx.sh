#!/bin/bash
# Recover the existing nginx installation and its network-dependent startup.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_config="$here/nginx-boot.conf"
destination=/etc/systemd/system/nginx.service.d/laplace-network.conf

if [[ ${1:-} == --check ]]; then
  systemctl show nginx --property=ActiveState,SubState,After,Wants,Restart,RestartUSec
  if [[ -f "$destination" ]] && cmp -s "$source_config" "$destination"; then
    systemctl is-active --quiet nginx
  else
    echo 'nginx network recovery configuration is not installed' >&2
    exit 1
  fi
  exit
fi
[[ $# == 0 ]] || { echo 'Usage: repair-nginx.sh [--check]' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Root is required to install the nginx unit override and start nginx.' >&2; exit 1; }
[[ -r "$source_config" ]] || { echo 'Missing nginx-boot.conf' >&2; exit 1; }
[[ $(systemctl show nginx --property=LoadState --value) == loaded ]] || { echo 'Existing nginx service not found' >&2; exit 1; }
[[ ! -L "$destination" ]] || { echo 'Refusing to replace a symlinked unit override' >&2; exit 1; }
if [[ -e "$destination" ]] && ! cmp -s "$source_config" "$destination"; then
  echo "Existing $destination differs; refusing to overwrite operator configuration." >&2
  exit 1
fi
# Validate the serving configuration before changing service policy.
/usr/sbin/nginx -t
install -d -o root -g root -m 755 /etc/systemd/system/nginx.service.d
candidate=$(mktemp /etc/systemd/system/nginx.service.d/.laplace-network.XXXXXX)
trap 'rm -f -- "$candidate"' EXIT
install -o root -g root -m 644 "$source_config" "$candidate"
mv -f -- "$candidate" "$destination"
systemctl daemon-reload
systemctl reset-failed nginx
systemctl start nginx
systemctl is-active --quiet nginx
[[ $(systemctl show nginx --property=Restart --value) == on-failure ]]
[[ $(systemctl show nginx --property=RestartUSec --value) == 10s ]]
systemctl show nginx --property=ActiveState,SubState,After,Wants,Restart,RestartUSec
printf 'nginx started; network ordering and restart recovery installed.\n'
