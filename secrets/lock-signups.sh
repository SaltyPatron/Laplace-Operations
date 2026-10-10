#!/usr/bin/env bash
# Run once your Vaultwarden account exists: closes public sign-up.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
F=/hosting/vaultwarden/compose.yaml
sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' "$F"
docker compose -f "$F" up -d
grep SIGNUPS_ALLOWED "$F"
