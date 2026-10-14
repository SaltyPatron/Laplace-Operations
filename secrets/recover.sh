#!/usr/bin/env bash
# Recover the existing Shamir-sealed Bao using its existing root-only escrow.
# Never initialize, change authentication, print keys, or install automatic unseal.
set -euo pipefail
set +x

bao_state() {
  curl --silent --show-error --fail --max-time 10 --noproxy '*' \
    http://127.0.0.1:8200/v1/sys/seal-status
}

bao_select_escrow() {
  case $# in
    0)
      echo 'OpenBao is sealed. No /root/openbao-init-*.json escrow file exists.' >&2
      echo 'The original setup instructed moving these shares offline and removing the local copy.' >&2
      echo 'Use bao operator unseal with the original offline shares, or --unseal-file PATH for an existing relocated escrow.' >&2
      return 1 ;;
    1) printf '%s\n' "$1" ;;
    *)
      printf 'OpenBao is sealed. Found %s escrow candidates; none selected:\n' "$#" >&2
      printf '  %s\n' "$@" >&2
      echo 'Select the escrow for this existing store with --unseal-file PATH; file contents have not been read.' >&2
      return 1 ;;
  esac
}

bao_unseal_existing() {
  local escrow=${1:-} state threshold progress index response
  state=$(bao_state)
  jq -e '.initialized == true and .type == "shamir" and .migration == false' <<<"$state" >/dev/null || {
    echo 'Existing initialized Shamir storage is required; no initialization or seal migration attempted.' >&2
    return 1
  }
  if jq -e '.sealed == false' <<<"$state" >/dev/null; then
    echo 'OpenBao is already unsealed; no keys read.'
    return
  fi
  threshold=$(jq -er '.t | select(type == "number" and . >= 1 and . <= 100 and floor == .)' <<<"$state")
  progress=$(jq -er '.progress | select(type == "number" and . >= 0)' <<<"$state")
  if [[ -z $escrow ]]; then
    local -a candidates
    shopt -s nullglob
    candidates=(/root/openbao-init-*.json)
    shopt -u nullglob
    escrow=$(bao_select_escrow "${candidates[@]}") || return 1
  fi
  [[ -f $escrow && ! -L $escrow ]] || { echo 'Escrow must be an existing regular file, not a symlink.' >&2; return 1; }
  local owner mode
  owner=$(stat -c %u -- "$escrow")
  mode=$(stat -c %a -- "$escrow")
  [[ $owner == 0 && $((8#$mode & 077)) == 0 ]] || {
    echo 'Escrow must already be root-owned and inaccessible to group/other; permissions unchanged.' >&2
    return 1
  }
  jq -e --argjson threshold "$threshold" '
    .unseal_keys_b64 | type == "array" and length >= $threshold and
    (.[0:$threshold] | all(type == "string" and length > 0)) and
    (.[0:$threshold] | unique | length == $threshold)
  ' "$escrow" >/dev/null || { echo 'Escrow lacks the required distinct shares.' >&2; return 1; }
  # Existing progress may include these same shares; submit each distinct stored
  # share once, stopping as soon as Bao confirms unsealed. Never reset progress.
  for ((index=0; index<threshold; index++)); do
    response=$(jq -c --argjson index "$index" '{key: .unseal_keys_b64[$index]}' "$escrow" |
      curl --silent --show-error --fail --max-time 10 --noproxy '*' \
        -X PUT --data-binary @- http://127.0.0.1:8200/v1/sys/unseal) || {
      echo 'OpenBao rejected an existing unseal share; no initialization or credential changes attempted.' >&2
      return 1
    }
    jq -e '.sealed == true or .sealed == false' <<<"$response" >/dev/null || {
      echo 'Invalid unseal response; stopping.' >&2; return 1;
    }
    if jq -e '.sealed == false' <<<"$response" >/dev/null; then
      echo 'OpenBao unsealed using existing escrow; authentication and stored secrets unchanged.'
      return
    fi
  done
  echo "OpenBao remains sealed after the stored threshold shares (initial progress $progress); stopping." >&2
  return 1
}

secrets_recover_main() {
  local here escrow='' check=0 code attempt
  here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  while (($#)); do
    case $1 in
      --check) check=1; shift ;;
      --unseal-file) [[ $# -ge 2 ]] || return 2; escrow=$2; shift 2 ;;
      *) echo 'Usage: recover.sh [--check] [--unseal-file EXISTING_ROOT_ESCROW]' >&2; return 2 ;;
    esac
  done
  [[ $(hostname -s) == hart-server ]] || { echo 'Recovery is declared for hart-server only.' >&2; return 1; }
  for program in curl jq stat flock; do
    command -v "$program" >/dev/null || { echo "Missing prerequisite: $program" >&2; return 1; }
  done
  if ((check)); then
    bao_state | jq '{initialized, sealed, type, t, n, progress}'
    bash "$here/../network/repair-nginx.sh" --check
    bao_state | jq -e '.initialized == true and .sealed == false' >/dev/null
    return
  fi
  [[ $EUID == 0 ]] || { echo 'Root is required to read the existing private escrow and recover nginx.' >&2; return 1; }
  exec 9>/run/lock/laplace-secrets-recovery.lock
  flock -n 9 || { echo 'Another secrets recovery is running.' >&2; return 1; }
  bash "$here/../network/repair-nginx.sh"
  bao_unseal_existing "$escrow"
  for ((attempt=0; attempt<30; attempt++)); do
    code=$(curl --silent --show-error --max-time 5 --noproxy '*' \
      --resolve openbao.hartonomous.com:443:192.168.1.2 --output /dev/null --write-out '%{http_code}' \
      https://openbao.hartonomous.com/v1/sys/health)
    [[ $code == 200 ]] && break
    sleep 1
  done
  [[ $code == 200 ]] || { echo "Bao remains unavailable through HTTPS (HTTP $code)." >&2; return 1; }
  code=$(curl --silent --show-error --max-time 5 --noproxy '*' \
    --resolve vault.hartonomous.com:443:192.168.1.2 --output /dev/null --write-out '%{http_code}' \
    https://vault.hartonomous.com/alive)
  [[ $code == 200 ]] || { echo "Vaultwarden HTTPS health failed (HTTP $code)." >&2; return 1; }
  echo 'OpenBao unsealed and healthy through HTTPS; Vaultwarden HTTPS alive. User login is a separate verification.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  secrets_recover_main "$@"
fi
