#!/usr/bin/env bash
# Use an authenticated operator to issue one credential for an existing host role.
set -euo pipefail
set +x
umask 077
[[ $# == 2 && $1 =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'enroll-host.sh HOST OUTPUT_JSON' >&2; exit 2; }
host=$1 output=$2
[[ ! -e $output ]] || { echo 'Credential file already exists; enrollment will not rotate it implicitly' >&2; exit 1; }
export BAO_ADDR=${BAO_ADDR:-https://openbao.hartonomous.com}
work=$(mktemp -d "$(dirname "$output")/.bao-enroll.XXXXXX")
trap 'rm -rf "$work"' EXIT
bao read -format=json "auth/approle/role/$host/role-id" > "$work/role"
bao write -f -format=json "auth/approle/role/$host/secret-id" > "$work/secret"
jq -n --slurpfile role "$work/role" --slurpfile secret "$work/secret" \
  '{role_id:$role[0].data.role_id,secret_id:$secret[0].data.secret_id}' > "$work/credentials"
jq -e '(.role_id | type == "string" and length > 0) and (.secret_id | type == "string" and length > 0)' "$work/credentials" >/dev/null
chmod 600 "$work/credentials"
ln "$work/credentials" "$output"
echo "Created credentials for existing AppRole $host at $output; install root-owned mode 600 on that host"
