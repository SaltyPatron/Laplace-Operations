#!/bin/bash
# Exercise nginx startup failure and automatic recovery with the shipped unit policy.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
unit="laplace-nginx-recovery-test-$$.service"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cleanup() {
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  rm -f -- "$unit_dir/$unit" "$unit_dir/$unit.d/network.conf"
  rmdir -- "$unit_dir/$unit.d" 2>/dev/null || true
  systemctl --user daemon-reload
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -p "$unit_dir/$unit.d"
cp "$repo/network/nginx-boot.conf" "$unit_dir/$unit.d/network.conf"
cat > "$unit_dir/$unit" <<EOF
[Unit]
Description=Isolated nginx startup recovery check
[Service]
Type=simple
ExecStart=/usr/sbin/nginx -p $scratch/ -c $scratch/nginx.conf -g "daemon off;"
EOF
systemctl --user daemon-reload
systemctl --user start "$unit"
for _ in {1..20}; do
  [[ $(systemctl --user show "$unit" --property=SubState --value) == auto-restart ]] && break
  sleep 0.1
done
[[ $(systemctl --user show "$unit" --property=SubState --value) == auto-restart ]]
[[ $(systemctl --user show "$unit" --property=ExecMainStatus --value) == 1 ]]
# An unprivileged Unix socket keeps the check off the host's serving ports.
cat > "$scratch/nginx.conf" <<EOF
pid $scratch/nginx.pid;
error_log $scratch/error.log;
events {}
http {
  access_log off;
  server {
    listen unix:$scratch/http.sock;
    location / { return 200 'recovered'; }
  }
}
EOF
for _ in {1..40}; do
  if [[ -S "$scratch/http.sock" ]] && curl --silent --fail --unix-socket "$scratch/http.sock" http://localhost/ > "$scratch/response"; then
    break
  fi
  sleep 0.5
done
[[ $(cat "$scratch/response") == recovered ]]
systemctl --user is-active --quiet "$unit"
[[ $(systemctl --user show "$unit" --property=NRestarts --value) -ge 1 ]]
[[ $(systemctl --user show "$unit" --property=RestartUSec --value) == 10s ]]
[[ " $(systemctl --user show "$unit" --property=After --value) " == *' network-online.target '* ]]
[[ " $(systemctl --user show "$unit" --property=Wants --value) " == *' network-online.target '* ]]
echo 'PASS: nginx recovered from a failed start using the shipped restart policy and served HTTP 200.'
