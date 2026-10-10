#!/usr/bin/env bash
# Retrieve the existing host appdb record with a host AppRole; never change DB passwords.
# appdb-sync.sh HOST CREDENTIALS_JSON CONNECT_HOST PGPASS [PGPASS ...]
set -euo pipefail
set +x
umask 077
[[ $# -ge 4 ]] || { echo 'appdb-sync.sh HOST CREDENTIALS_JSON CONNECT_HOST PGPASS [PGPASS ...]' >&2; exit 2; }
host=$1 credentials=$2 connect_host=$3; shift 3
[[ $host =~ ^[A-Za-z0-9._-]+$ && $connect_host =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid host declaration' >&2; exit 2; }
address=${BAO_ADDR:-https://openbao.hartonomous.com}
[[ $address == https://* ]] || { echo 'Bao HTTPS address required' >&2; exit 2; }
[[ -r $credentials && -s $credentials ]] || { echo 'Host AppRole credential file missing or unreadable' >&2; exit 1; }
[[ $(stat -c %a "$credentials") == 600 || $(stat -c %a "$credentials") == 400 ]] || { echo 'Host credentials must be mode 600 or 400' >&2; exit 1; }
jq -e '(.role_id | type == "string" and length > 0) and (.secret_id | type == "string" and length > 0)' "$credentials" >/dev/null
work=$(mktemp -d "$(dirname "$1")/.bao-sync.XXXXXX")
token=''
request() {
  printf 'header = "X-Vault-Token: %s"\n' "$token" |
    curl --config - --connect-timeout 10 --max-time 30 -fsS "$@"
}
cleanup() {
  if [[ -n $token ]]; then request -X POST "$address/v1/auth/token/revoke-self" >/dev/null 2>&1 || echo 'Bao session revocation failed; token remains subject to its TTL' >&2; fi
  rm -rf "$work"
}
trap cleanup EXIT
curl --connect-timeout 10 --max-time 30 -fsS -H 'Content-Type: application/json' \
  --data-binary "@$credentials" "$address/v1/auth/approle/login" > "$work/session.json"
token=$(jq -er '.auth.client_token | select(type == "string" and length > 0)' "$work/session.json")
[[ $token =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid Bao session response' >&2; exit 1; }
request "$address/v1/kv/data/hosts/$host/appdb" > "$work/record.json"
jq -e --arg host "$host" '.data.data | .host == $host and
  (.port | tostring | test("^[0-9]+$")) and
  (.database | type == "string" and test("^[A-Za-z0-9_-]+$")) and
  (.role | type == "string" and test("^[A-Za-z0-9_-]+$")) and
  (.password | type == "string" and length > 0 and (explode | all(. != 0 and . != 10 and . != 13)))' "$work/record.json" >/dev/null
port=$(jq -r '.data.data.port' "$work/record.json")
database=$(jq -r '.data.data.database' "$work/record.json")
role=$(jq -r '.data.data.role' "$work/record.json")
password=$(jq -r '.data.data.password' "$work/record.json")
PGPASSWORD=$password PGCONNECT_TIMEOUT=10 psql -X -w -h "$connect_host" -p "$port" -U "$role" -d "$database" -Atqc 'SELECT 1' > "$work/connection-check"
[[ $(cat "$work/connection-check") == 1 ]] || { echo 'AppDB authentication check failed' >&2; exit 1; }
escaped=${password//\\/\\\\}; escaped=${escaped//:/\\:}
count=0
for destination in "$@"; do
  [[ -f $destination && ! -L $destination ]] || { echo "Existing regular credential file required: $destination" >&2; exit 1; }
  count=$((count+1))
  printf '%s:%s:%s:%s:%s\n' "$connect_host" "$port" "$database" "$role" "$escaped" > "$work/$count"
  awk -F: -v h="$connect_host" -v p="$port" -v d="$database" -v r="$role" \
    '!($1 == h && $2 == p && $3 == d && $4 == r)' "$destination" >> "$work/$count"
done
unset password escaped
count=0
for destination in "$@"; do
  count=$((count+1))
  staged=$(mktemp "$(dirname "$destination")/.pgpass-bao.XXXXXX")
  if ! { cat "$work/$count" > "$staged" && chmod 600 "$staged" && chown --reference="$destination" "$staged" && mv -f "$staged" "$destination"; }; then
    rm -f "$staged"; exit 1
  fi
done
echo "AppDB credentials refreshed from kv/hosts/$host/appdb for $count consumer(s); database authentication passed"
