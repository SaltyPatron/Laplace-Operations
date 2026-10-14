#!/usr/bin/env bash
# Exercise the shipped recovery function without root or a live unseal request.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
source "$repo/secrets/recover.sh"
escrow="$scratch/escrow.json"
printf '%s\n' '{"unseal_keys_b64":["fixture-one","fixture-two","fixture-three"],"root_token":"fixture-root-never-used"}' > "$escrow"
chmod 600 "$escrow"
# Only ownership is simulated. Mode, symlink checks and JSON parsing are real.
stat() {
  if [[ $1 == -c && $2 == %u ]]; then printf '%s\n' "${test_owner:-0}";
  else command stat "$@"; fi
}
curl() {
  [[ $* != *fixture-* ]] || { echo 'A key leaked into argv' >&2; return 90; }
  case ${*: -1} in
    http://127.0.0.1:8200/v1/sys/seal-status)
      cat "$scratch/state.json" ;;
    http://127.0.0.1:8200/v1/sys/unseal)
      [[ $* == *'--data-binary @-'* ]] || return 91
      local key count
      key=$(jq -er '.key')
      [[ $key == fixture-* && $key != fixture-root-never-used ]] || return 92
      printf '%s\n' "$key" >> "$scratch/submitted"
      count=$(wc -l < "$scratch/submitted")
      if [[ ${reject_share:-0} == 1 ]]; then return 22; fi
      if ((count == 3)); then printf '%s\n' '{"sealed":false}';
      else printf '%s\n' '{"sealed":true}'; fi ;;
    *) echo 'Unexpected request; initialization and authentication are forbidden in this test.' >&2; return 93 ;;
  esac
}
reset_state() {
  printf '%s\n' '{"initialized":true,"sealed":true,"type":"shamir","migration":false,"t":3,"progress":0}' > "$scratch/state.json"
  : > "$scratch/submitted"
}
expect_failure() {
  local status=0
  # A separate shell with errexit active checks the production failure behavior.
  (set -e; bao_unseal_existing "$1") > "$scratch/output" 2>&1 || status=$?
  [[ $status != 0 ]] || { echo 'Expected recovery failure' >&2; exit 1; }
}
reset_state
bao_unseal_existing "$escrow" > "$scratch/output"
[[ $(wc -l < "$scratch/submitted") == 3 ]]
if grep -q 'fixture-' "$scratch/output"; then echo 'Key exposed in output' >&2; exit 1; fi
echo 'PASS: threshold shares travel only through stdin; root token unused; stops when unsealed.'

reset_state
sed -i 's/"sealed":true/"sealed":false/' "$scratch/state.json"
bao_unseal_existing /nonexistent/escrow > "$scratch/output"
[[ ! -s "$scratch/submitted" ]]
echo 'PASS: already unsealed does not require or read escrow.'

reset_state
sed -i 's/"initialized":true/"initialized":false/' "$scratch/state.json"
expect_failure "$escrow"
[[ ! -s "$scratch/submitted" ]]
echo 'PASS: uninitialized storage is refused without initialization.'

reset_state
chmod 644 "$escrow"
expect_failure "$escrow"
[[ ! -s "$scratch/submitted" ]]
chmod 600 "$escrow"
test_owner=1000
expect_failure "$escrow"
[[ ! -s "$scratch/submitted" ]]
test_owner=0
ln -s "$escrow" "$scratch/link"
expect_failure "$scratch/link"
[[ ! -s "$scratch/submitted" ]]
echo 'PASS: public, non-root and symlinked escrow refused before submitting shares.'
expect_failure "$scratch/missing"
[[ ! -s "$scratch/submitted" ]]
echo 'PASS: missing escrow leaves sealed storage untouched.'

reset_state
reject_share=1
expect_failure "$escrow"
[[ $(wc -l < "$scratch/submitted") == 1 ]]
if grep -q 'fixture-' "$scratch/output"; then echo 'Key exposed in output' >&2; exit 1; fi
reject_share=0
echo 'PASS: rejected share stops immediately; no reset, retry loop or credential exposure.'

reset_state
sed -i 's/fixture-two/fixture-one/' "$escrow"
expect_failure "$escrow"
[[ ! -s "$scratch/submitted" ]]
echo 'PASS: duplicate shares refused before unseal.'
