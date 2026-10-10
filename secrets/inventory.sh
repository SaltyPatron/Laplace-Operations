#!/usr/bin/env bash
# Metadata and field names only; secret values and authentication tokens never print.
set -euo pipefail
set +x
export BAO_ADDR=${BAO_ADDR:-https://openbao.hartonomous.com}
bao token lookup -format=json | jq '{kind:"session",policies:.data.policies,ttl:.data.ttl,renewable:.data.renewable}'
roles=$(bao list -format=json auth/approle/role)
while IFS= read -r role; do
  [[ $role =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Unexpected role name' >&2; exit 1; }
  bao read -format=json "auth/approle/role/$role" | jq --arg role "$role" \
    '{kind:"approle",role:$role,policies:.data.token_policies,bind_secret_id:.data.bind_secret_id,
      token_ttl:.data.token_ttl,token_max_ttl:.data.token_max_ttl,secret_id_ttl:.data.secret_id_ttl}'
done < <(jq -r '.[]' <<< "$roles")
inventory_kv() {
  local path=$1 names name
  names=$(bao list -format=json "kv/metadata/$path")
  while IFS= read -r name; do
    [[ $name =~ ^[A-Za-z0-9._-]+/?$ ]] || { echo 'Unexpected secret path component' >&2; exit 1; }
    if [[ $name == */ ]]; then
      inventory_kv "$path$name"
    else
      bao read -format=json "kv/data/$path$name" | jq --arg path "kv/$path$name" \
        '{kind:"secret-metadata",path:$path,version:.data.metadata.version,
          fields:(.data.data | if type == "object" then keys else error("expected a KV object") end)}'
    fi
  done < <(jq -r '.[]' <<< "$names")
}
inventory_kv hosts/
inventory_kv shared/
