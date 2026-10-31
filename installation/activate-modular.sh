#!/usr/bin/env bash
# Recurring activation. The caller owns the host lock and database-cache binding;
# its existing package verifier supplies the runtime verification command.
set -eEuo pipefail
[[ $# -ge 7 ]] || { echo 'Expected selection, release, receipt, unit, expected environment, -- and verifier' >&2; exit 2; }
selection=$1 release=$2 receipt=$3 unit_file=$4 expected_environment=$5
shift 5
[[ $1 == -- ]] || { echo 'Missing verifier separator' >&2; exit 2; }
shift
verify=("$@")
prefix=$(jq -er '.prefix' "$selection")
environment=$(jq -er '.environment_file' "$selection")
signal=$(jq -er '.restart_signal' "$selection")
current=$prefix/current
record=$prefix/.activation.json
credential=$(dirname "$environment")/secrets/modular-mcp.env
unit=laplace-modular-mcp.service
unit_expected=$(mktemp "$receipt/.unit.XXXXXXXX")
link_work=
fresh=
mutated=0
cleanup() {
  rm -f -- "$unit_expected"
  [[ -z $link_work ]] || rm -rf -- "$link_work"
  [[ -z $fresh ]] || rm -f -- "$fresh"
}
trap cleanup EXIT
cat > "$unit_expected"
fail() { echo "$*" >&2; return 1; }
hash_file() {
  local value
  value=$(sha256sum < "$1") || return
  printf '%s' "${value%% *}"
}
link_identity() { stat -c '%d:%i:%z' -- "$current"; }
switch_link() {
  [[ ! -e $current || -L $current ]] || fail 'Active release path must be a symlink'
  link_work=$(mktemp -d "$prefix/.current.XXXXXXXX")
  ln -s -- "$1" "$link_work/current"
  mv -Tf -- "$link_work/current" "$current"
  rmdir -- "$link_work"
  link_work=
}
read_state() {
  local state key value
  state=$(systemctl show "$unit" -p InvocationID -p ActiveState) || return
  invocation= active=
  while IFS='=' read -r key value; do
    case $key in InvocationID) invocation=$value ;; ActiveState) active=$value ;; esac
  done <<< "$state"
}
verify_runtime() { "${verify[@]}" --release "$release" --output "$receipt/runtime.json"; }
check_environment() {
  # Resource paths are pinned again by the immutable executable launchers. Older
  # installations legitimately retain their original fallback values here.
  local line key value
  declare -A installed=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^([A-Z_][A-Z_0-9]*)=(.*)$ ]] || fail 'Unsupported installed environment assignment'
    installed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done < "$environment"
  while IFS='=' read -r key value; do
    case $key in
      PATH|LANG|LAPLACE_TIER0|LAPLACE_FLAGS|LAPLACE_HIGHWAY|LAPLACE_GRAMMARS|LAPLACE_ENGINE|LAPLACE_RECIPES|LAPLACE_MANIFEST|LAPLACE_FIRMWARE) continue ;;
    esac
    [[ -n ${installed[$key]+x} && ${installed[$key]} == "$value" ]] || fail "Installed service environment differs for $key"
  done < "$expected_environment"
}
configuration_identity() { stat -c '%d:%i:%z' -- "$unit_file" "$environment" "$credential"; }
check_configuration() {
  [[ $(hash_file "$unit_file") == "$unit_hash" &&
     $(hash_file "$environment") == "$environment_hash" &&
     $(hash_file "$credential") == "$credential_hash" ]] || fail 'Service configuration changed during verification'
}
write_record() {
  jq -n --arg release "$release" --arg link "$(link_identity)" --arg unit "$unit_hash" \
    --arg environment "$environment_hash" --arg credential "$credential_hash" \
    --arg configuration "$(configuration_identity)" \
    --arg invocation "$invocation" --arg action "$1" --arg utc "$(date -u +%FT%TZ)" \
    '{schema:"laplace.modular-activation/v1",result:"passed",release:$release,link:$link,
      unit_sha256:$unit,environment_sha256:$environment,credential_sha256:$credential,
      configuration:$configuration,invocation:$invocation,action:$action,checked_utc:$utc}' > "$receipt/activation.json"
}

[[ -d $release && ! -L $release ]] || fail 'Selected release must be a real directory'
release=$(realpath -e -- "$release")
releases=$(realpath -e -- "$prefix/releases")
[[ $(dirname "$release") == "$releases" ]] || fail 'Selected release is outside its installation'
[[ -L $current ]] || fail 'Recurring deployment requires an installed release symlink'
previous=$(readlink -- "$current")
selected=$(realpath -e -- "$current")
[[ $(dirname "$selected") == "$releases" ]] || fail 'Current release is outside its installation'
[[ ! -L $signal && ! -L $record ]] || fail 'Activation state must not redirect through a symlink'
cmp -s -- "$unit_expected" "$unit_file" || fail 'Installed service unit differs from its declaration'
check_environment
unit_hash=$(hash_file "$unit_file")
environment_hash=$(hash_file "$environment")
credential_hash=$(hash_file "$credential")
identity=$(link_identity)
read_state
before=$invocation

if [[ -f $record ]]; then
  jq -e '.schema == "laplace.modular-activation/v1" and .result == "passed"' "$record" > /dev/null
  if [[ $selected == "$release" && $active == active && -n $invocation && ! -e $signal ]] &&
     jq -e --arg release "$release" --arg link "$identity" --arg unit "$unit_hash" \
       --arg environment "$environment_hash" --arg credential "$credential_hash" \
       --arg invocation "$invocation" --arg configuration "$(configuration_identity)" \
       '.release == $release and .link == $link and .unit_sha256 == $unit and
        .environment_sha256 == $environment and .credential_sha256 == $credential and
        (.invocation == $invocation or .configuration == $configuration)' "$record" > /dev/null; then
    if verify_runtime; then
      read_state
      [[ $active == active && $invocation == "$before" && $(link_identity) == "$identity" && ! -e $signal ]] ||
        fail 'Runtime changed during unchanged-release verification'
      check_configuration
      write_record reused
      echo 'Verified unchanged modular release; running service retained'
      exit 0
    fi
    echo 'Current runtime verification failed; requesting activation of its selected release' >&2
  fi
fi

rollback() {
  local status=$?
  trap - ERR
  if [[ $mutated == 1 ]]; then
    if [[ -L $current && $(realpath -e -- "$current") == "$release" ]]; then
      switch_link "$previous"
      touch -- "$signal"
      # The caller restores the prior database-cache binding as it unwinds.
      # The existing service path consumes this request after that restoration.
      echo 'Activation failed; previous release restored and restart requested' >&2
    elif [[ -L $current && $(realpath -e -- "$current") == "$selected" ]]; then
      echo 'Activation failed before changing the selected release' >&2
    else
      echo 'Activation failed; current release changed outside this operation, so rollback was refused' >&2
    fi
  fi
  exit "$status"
}
trap rollback ERR
mutated=1
if [[ $selected != "$release" ]]; then switch_link "$release"; fi
touch -- "$signal"
ready=0
for ((attempt=0; attempt<100; attempt++)); do
  read_state
  if [[ $active == active && -n $invocation && $invocation != "$before" ]]; then ready=1; break; fi
  sleep .2
done
[[ $ready == 1 ]] || fail 'Service did not activate the selected executable'
cmp -s -- "$unit_expected" "$unit_file" || fail 'Installed service unit changed during activation'
ready_invocation=$invocation
verify_runtime
read_state
[[ $active == active && $invocation == "$ready_invocation" && $(realpath -e -- "$current") == "$release" ]] ||
  fail 'Runtime changed during activation verification'
check_configuration
write_record activated
fresh=$(mktemp "$prefix/.activation.XXXXXXXX")
cp -- "$receipt/activation.json" "$fresh"
chmod 664 "$fresh"
mv -f -- "$fresh" "$record"
fresh=
mutated=0
echo 'Selected modular release activated and verified'
