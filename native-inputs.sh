#!/usr/bin/env bash
# Resolve qualified Native inputs and retain their verified bytes on the CI estate.
set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
digest() { local value; value=$(sha256sum < "$1") || return; printf '%s' "${value%% *}"; }
resolve() {
  local owner=$1 revision=$2 runs eligible run jobs artifacts passed available pending expired=
  [[ $owner =~ ^[A-Za-z0-9-]+$ && $revision =~ ^[0-9a-f]{40}$ ]] || fail 'Expected repository owner and full Native revision'
  runs=$(gh api --paginate "repos/$owner/Laplace-Native/actions/runs?head_sha=$revision&per_page=100") || return
  eligible=$(jq -sr --arg revision "$revision" '[.[].workflow_runs[] | select(.head_sha == $revision and
    .head_branch == "main" and .path == ".github/workflows/laplace.yml" and
    (.event == "push" or .event == "workflow_dispatch"))] | .[].id' <<< "$runs") || return
  while IFS= read -r run; do
    [[ -n $run ]] || continue
    jobs=$(gh api --paginate "repos/$owner/Laplace-Native/actions/runs/$run/jobs?per_page=100") || return
    passed=$(jq -sr '[.[].jobs[] | select(.conclusion == "success") | .name] |
      contains(["native (icx-release)","native (gcc-release)","isa"])' <<< "$jobs") || return
    [[ $passed == true ]] || continue
    artifacts=$(gh api --paginate "repos/$owner/Laplace-Native/actions/runs/$run/artifacts?per_page=100") || return
    available=$(jq -sr 'any(.[].artifacts[]; .name == "native-prepared-inputs" and .expired == false)' <<< "$artifacts") || return
    if [[ $available == true ]]; then
      printf '%s\n' "$run"
      return
    fi
    expired=$run
  done <<< "$eligible"
  # A passing run whose inputs expired (Native keeps them 7 days): run it again for the same revision, once, and wait.
  if [[ -n ${expired:-} && -z ${NATIVE_INPUTS_RERUN:-} ]]; then
    echo "Native inputs of run $expired for $revision expired; running it again to regenerate them" >&2
    gh run rerun "$expired" --repo "$owner/Laplace-Native" >&2 || fail "Native inputs for $revision expired and run $expired could not be rerun"
    export NATIVE_INPUTS_RERUN=$expired; sleep 30; resolve "$owner" "$revision"; return
  fi
  # Siblings build from Native main; wait while its run for this revision is queued or executing (Native has its own runner).
  pending=$(jq -sr --arg revision "$revision" '[.[].workflow_runs[] | select(.head_sha == $revision and
    .head_branch == "main" and .path == ".github/workflows/laplace.yml" and (.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "pending" or .status == "requested"))] | length' <<< "$runs") || return
  if (( pending > 0 && SECONDS < ${LAPLACE_NATIVE_WAIT:-5400} )); then
    echo "Native run for $revision not finished; waiting" >&2; sleep 60; resolve "$owner" "$revision"; return
  fi
  fail "No verified Native cache artifact for revision $revision: no passing Native main run for it$([[ -n ${NATIVE_INPUTS_RERUN:-} ]] && echo " (rerun of $NATIVE_INPUTS_RERUN did not finish within ${LAPLACE_NATIVE_WAIT:-5400} s)")"
}
verify() {
  local directory=$1 name expected bytes
  [[ -f $directory/manifest.json && ! -L $directory/manifest.json ]] || fail 'Prepared manifest must be a regular file'
  jq -e 'keys == ["tier0.bin","tier0.flags","tier0.flags.layout","tier0.highway"] and
    all(.[]; (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.bytes | type == "number" and . > 0 and floor == .))' "$directory/manifest.json" > /dev/null
  for name in tier0.bin tier0.flags tier0.flags.layout tier0.highway; do
    [[ -f $directory/$name && ! -L $directory/$name ]] || fail "Missing regular prepared input: $name"
    expected=$(jq -er --arg name "$name" '.[$name].sha256' "$directory/manifest.json")
    bytes=$(jq -er --arg name "$name" '.[$name].bytes' "$directory/manifest.json")
    [[ $(stat -c %s -- "$directory/$name") == "$bytes" && $(digest "$directory/$name") == "$expected" ]] ||
      fail "Prepared input digest mismatch: $name"
  done
}
emit() {
  local directory=$1
  printf 'LAPLACE_TIER0=%s/tier0.bin\nLAPLACE_FLAGS=%s/tier0.flags\nLAPLACE_HIGHWAY=%s/tier0.highway\n' \
    "$directory" "$directory" "$directory" >> "$GITHUB_ENV"
}
publish_readers() {
  # These owned copies contain public prepared inputs. PostgreSQL reads them as
  # its own OS account; mktemp's private entry mode must not block that reader.
  local directory=$1 name mode
  mode=$(stat -c %a -- "$directory")
  (( (8#$mode & 0555) == 0555 )) || chmod a+rx -- "$directory"
  for name in manifest.json tier0.bin tier0.flags tier0.flags.layout tier0.highway .laplace-prepared-cache; do
    mode=$(stat -c %a -- "$directory/$name")
    (( (8#$mode & 0444) == 0444 )) || chmod a+r -- "$directory/$name"
  done
}
prepare() (
  [[ ${GITHUB_ACTIONS:-} == true ]] || fail 'Prepared input selection is a CI operation'
  : "${LAPLACE_BUILD:?}" "${GITHUB_ENV:?}" "${RUNNER_TEMP:?}" "${GITHUB_REPOSITORY_OWNER:?}"
  local native=$1 revision base selection cache expected marker run temporary= fresh= cursor= component
  revision=$(git -C "$native" rev-parse --verify HEAD)
  [[ -z $(git -C "$native" status --porcelain --untracked-files=no) ]] || fail 'Selected Native sources have uncommitted changes'
  [[ $LAPLACE_BUILD == /* && $LAPLACE_BUILD != / && $LAPLACE_BUILD != *$'\n'* && $LAPLACE_BUILD != *$'\r'* ]] || fail 'Expected an absolute CI build root'
  base=$LAPLACE_BUILD/Laplace-Native
  IFS=/ read -r -a components <<< "$base/prepared"
  for component in "${components[@]}"; do
    [[ -n $component ]] || continue
    [[ $component != . && $component != .. ]] || fail 'CI build root must be normalized'
    cursor=$cursor/$component
    [[ ! -L $cursor ]] || fail "CI build root traverses a symlink: $cursor"
  done
  mkdir -p "$base"
  selection=$base/selected-inputs.json
  [[ ! -L $selection ]] || fail 'Prepared input selection must not be a symlink'
  trap '[[ -z "$temporary" ]] || rm -rf -- "$temporary"; [[ -z "$fresh" ]] || rm -f -- "$fresh"' EXIT
  if [[ -f $selection ]]; then
    jq -e '.schema == "laplace.native-input-selection/v1" and
      (.native | type == "string" and test("^[0-9a-f]{40}$")) and
      (.cache | type == "string") and
      (.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.qualified_run | type == "number" and . > 0 and floor == .)' "$selection" > /dev/null
    if [[ $(jq -er '.native' "$selection") == "$revision" ]]; then
      cache=$(jq -er '.cache' "$selection")
      [[ ${cache%/*} == "$base/prepared" && ${cache##*/} =~ ^[0-9a-f]{64}$ ]] || fail 'Prepared selection escaped its cache owner'
      if [[ -d $cache ]]; then
        marker=$cache/.laplace-prepared-cache
        [[ ! -L $cache && -f $marker && ! -L $marker ]] || fail 'Selected prepared cache is not owned'
        [[ $(< "$marker") == 'laplace.native-prepared-cache/v1'$'\n'"${cache##*/}" ]] || fail 'Selected prepared cache marker differs'
        expected=$(jq -er '.manifest_sha256' "$selection")
        [[ $(digest "$cache/manifest.json") == "$expected" ]] || fail 'Selected prepared manifest differs'
        verify "$cache"
        publish_readers "$cache"
        touch -- "$marker"
        emit "$cache"
        echo "Reused verified Native inputs: $revision"
        exit 0
      fi
    fi
  fi
  run=$(resolve "$GITHUB_REPOSITORY_OWNER" "$revision")
  temporary=$(mktemp -d "$RUNNER_TEMP/native-inputs.XXXXXXXX")
  gh run download "$run" --repo "$GITHUB_REPOSITORY_OWNER/Laplace-Native" --name native-prepared-inputs --dir "$temporary"
  verify "$temporary"
  cache=$(LAPLACE_TIER0="$temporary/tier0.bin" bash "$native/scripts/ci-prepared-inputs.sh")
  verify "$cache"
  publish_readers "$cache"
  fresh=$(mktemp "$base/.selected-inputs.XXXXXXXX")
  jq -n --arg native "$revision" --arg cache "$cache" --arg manifest "$(digest "$cache/manifest.json")" --argjson run "$run" \
    '{schema:"laplace.native-input-selection/v1",native:$native,cache:$cache,manifest_sha256:$manifest,qualified_run:$run}' > "$fresh"
  chmod 664 "$fresh"
  mv -f -- "$fresh" "$selection"
  fresh=
  emit "$cache"
  echo "Selected qualified Native inputs: $revision, run $run"
)
case ${1:-} in
  resolve) [[ $# == 3 ]] || exit 2; resolve "$2" "$3" ;;
  prepare) [[ $# == 2 ]] || exit 2; prepare "$2" ;;
  *) echo 'Usage: native-inputs.sh resolve OWNER REVISION | prepare NATIVE_SOURCE' >&2; exit 2 ;;
esac
