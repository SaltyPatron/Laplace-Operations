#!/usr/bin/env bash
# Publish the secrets stack: system-wide BAO_ADDR, nginx reload once no GitHub Actions job is running, verify.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ADDR=https://openbao.hartonomous.com

# System-wide client address for every user and shell (PAM reads /etc/environment at login)
if grep -q '^BAO_ADDR=' /etc/environment; then sed -i "s|^BAO_ADDR=.*|BAO_ADDR=$ADDR|" /etc/environment
else echo "BAO_ADDR=$ADDR" >> /etc/environment; fi
echo "BAO_ADDR=$ADDR set in /etc/environment"

# Don't reload nginx under a running deploy
[[ "${1:-}" == "--now" ]] || while pgrep -f "Runner.Worker" >/dev/null; do echo "$(date +%T) deploy job running; waiting... (Ctrl+C, then re-run with --now to skip)"; sleep 20; done
nginx -t && systemctl reload nginx && echo "nginx reloaded"

sleep 2
for u in https://vault.hartonomous.com/alive "$ADDR/v1/sys/health"; do
  code=$(curl --max-time 15 -sS -o /dev/null -w '%{http_code}' "$u")
  printf '%-50s %s\n' "$u" "$code"
  [[ $code == 200 ]] || { echo 'Secrets endpoint health check failed' >&2; exit 1; }
done
echo "Log out and back in (or open a new SSH session) so BAO_ADDR is picked up, then: bao login -method=userpass username=ahart"
