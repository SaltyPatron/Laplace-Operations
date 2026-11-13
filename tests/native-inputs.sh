#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?use build scratch storage}/native-inputs.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/native/scripts" "$work/input" "$work/temp"
export NATIVE_INPUT_FIXTURE=$work GITHUB_ACTIONS=true GITHUB_REPOSITORY_OWNER=fixture
export RUNNER_TEMP="$work/temp" LAPLACE_BUILD="$work/build with spaces" GITHUB_ENV="$work/job.env"
export PATH="$work/bin:$PATH"
touch "$work/gh.log"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NATIVE_INPUT_FIXTURE/gh.log"
[[ ${NATIVE_OFFLINE:-0} != 1 ]] || { echo 'fixture network disabled' >&2; exit 54; }
[[ ${NATIVE_API_ERROR:-0} != 1 ]] || { echo 'fixture API failed' >&2; exit 55; }
if [[ $1 == api ]]; then
  shift
  [[ $1 != --paginate ]] || shift
  [[ ${NATIVE_INVALID_JSON:-0} != 1 ]] || { printf 'not JSON\n'; exit 0; }
  case $1 in
    */actions/runs\?*) jq -n --arg revision "${NATIVE_RUN_REVISION:-$NATIVE_REVISION}" --arg branch "${NATIVE_RUN_BRANCH:-main}" \
      '{workflow_runs:[{id:7,head_sha:$revision,head_branch:$branch,path:".github/workflows/laplace.yml",event:"push"}]}' ;;
    */jobs\?*) jq -n --arg missing "${NATIVE_MISSING_JOB:-}" '{jobs:["native (icx-release)","native (gcc-release)","isa"] |
      map(. as $name | {name:$name,conclusion:(if $name==$missing then "failure" else "success" end)})}' ;;
    */artifacts\?*) jq -n --argjson expired "${NATIVE_EXPIRED:-false}" '{artifacts:[{name:"native-prepared-inputs",expired:$expired}]}' ;;
    *) exit 90 ;;
  esac
elif [[ $1 == run && $2 == download ]]; then
  while [[ $# -gt 0 && $1 != --dir ]]; do shift; done
  [[ $# == 2 ]] || exit 91
  cp -a "$NATIVE_INPUT_FIXTURE/input/." "$2/"
else exit 92
fi
SH
chmod +x "$work/bin/gh"
# The cache owner is an external interface here; its own real implementation is
# covered by Native's prepared-input fixture. This fixture checks selection/verification.
cat > "$work/native/scripts/ci-prepared-inputs.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
key=$(printf '%064d' 1)
cache=$LAPLACE_BUILD/Laplace-Native/prepared/$key
if [[ ! -d $cache ]]; then
  mkdir -p "$cache"
  chmod 2700 "$cache"
  cp -a "${LAPLACE_TIER0%/*}/." "$cache/"
  printf 'laplace.native-prepared-cache/v1\n%s\n' "$key" > "$cache/.laplace-prepared-cache"
fi
printf '%s\n' "$cache"
SH
git -C "$work/native" init -q
git -C "$work/native" add scripts
git -C "$work/native" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
export NATIVE_REVISION=$(git -C "$work/native" rev-parse HEAD)
test "$(bash "$ROOT/native-inputs.sh" resolve fixture "$NATIVE_REVISION")" = 7
for missing in 'native (icx-release)' 'native (gcc-release)'; do
  if NATIVE_MISSING_JOB="$missing" bash "$ROOT/native-inputs.sh" resolve fixture "$NATIVE_REVISION" > "$work/rejected.log" 2>&1; then
    echo "FAIL incomplete qualification accepted: $missing" >&2; exit 1
  fi
done
for rejected in NATIVE_EXPIRED=true NATIVE_RUN_BRANCH=feature NATIVE_RUN_REVISION=0000000000000000000000000000000000000000; do
  if env "$rejected" bash "$ROOT/native-inputs.sh" resolve fixture "$NATIVE_REVISION" > "$work/rejected.log" 2>&1; then
    echo "FAIL unqualified Native artifact accepted: $rejected" >&2; exit 1
  fi
done
for rejected in NATIVE_API_ERROR=1 NATIVE_INVALID_JSON=1; do
  if env "$rejected" bash "$ROOT/native-inputs.sh" resolve fixture "$NATIVE_REVISION" > "$work/rejected.log" 2>&1; then
    echo "FAIL broken API response accepted: $rejected" >&2; exit 1
  fi
done
echo 'PASS Native selection requires matching main revision, compiler/ISA success and live artifact; API errors fail'

printf '{}\n' > "$work/input/manifest.json"
for name in tier0.bin tier0.flags tier0.flags.layout tier0.highway; do
  printf 'fixture %s\n' "$name" > "$work/input/$name"
  sum=$(sha256sum < "$work/input/$name"); sum=${sum%% *}
  bytes=$(stat -c %s "$work/input/$name")
  jq --arg name "$name" --arg sum "$sum" --argjson bytes "$bytes" '.[$name]={sha256:$sum,bytes:$bytes}' \
    "$work/input/manifest.json" > "$work/input/next.json"
  mv "$work/input/next.json" "$work/input/manifest.json"
done
bash "$ROOT/native-inputs.sh" prepare "$work/native"
cache=$(jq -er .cache "$LAPLACE_BUILD/Laplace-Native/selected-inputs.json")
mode=$(stat -c %a "$cache")
(( (8#$mode & 0055) == 0055 ))
echo 'PASS verified cache permits traversal by the separate PostgreSQL OS reader'
snapshot() { for name in tier0.bin tier0.flags tier0.flags.layout tier0.highway; do stat -c '%n %i %y' "$cache/$name"; done; }
snapshot > "$work/before"
calls=$(wc -l < "$work/gh.log")
NATIVE_OFFLINE=1 bash "$ROOT/native-inputs.sh" prepare "$work/native"
snapshot > "$work/after"
diff -u "$work/before" "$work/after"
test "$(wc -l < "$work/gh.log")" = "$calls"
test "$(find "$RUNNER_TEMP" -mindepth 1 -maxdepth 1 | wc -l)" = 0
echo 'PASS matching verified local inputs retain inode/mtime and remain usable without artifact/network availability'

touch -r "$cache/tier0.bin" "$work/original-time"
printf 'corrupt\n' > "$cache/tier0.bin"
touch -r "$work/original-time" "$cache/tier0.bin"
if NATIVE_OFFLINE=1 bash "$ROOT/native-inputs.sh" prepare "$work/native" > "$work/corrupt.log" 2>&1; then
  echo 'FAIL corrupted cache accepted' >&2; exit 1
fi
grep -Fq 'Prepared input digest mismatch: tier0.bin' "$work/corrupt.log"
test "$(wc -l < "$work/gh.log")" = "$calls"
echo 'PASS corrupted cached bytes fail instead of silently selecting or overwriting another closure'

mv "$LAPLACE_BUILD/Laplace-Native/prepared" "$work/retained-prepared"
ln -s "$work/retained-prepared" "$LAPLACE_BUILD/Laplace-Native/prepared"
if NATIVE_OFFLINE=1 bash "$ROOT/native-inputs.sh" prepare "$work/native" > "$work/redirected.log" 2>&1; then
  echo 'FAIL redirected cache parent accepted' >&2; exit 1
fi
grep -Fq 'CI build root traverses a symlink' "$work/redirected.log"
test "$(wc -l < "$work/gh.log")" = "$calls"
echo 'PASS a redirected cache parent is refused before cache access or permission publication'
