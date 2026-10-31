#!/usr/bin/env bash
# Run the real recurring activation owner with isolated service and verifier commands.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?use build scratch storage}/modular-activation.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
export ACTIVATION_FIXTURE=$work
mkdir -p "$work/bin" "$work/install with spaces/releases/old" "$work/install with spaces/releases/new" \
  "$work/install with spaces/releases/broken" "$work/runtime/secrets"
prefix="$work/install with spaces"
ln -s releases/old "$prefix/current"
printf 'declared unit\n' > "$work/unit"
printf 'OMP_NUM_THREADS="4"\nLAPLACE_TIER0="/original/fallback/tier0.bin"\n' > "$work/runtime/environment"
cp "$work/runtime/environment" "$work/environment.original"
printf 'OMP_NUM_THREADS="4"\nLAPLACE_TIER0="/packaged/immutable/tier0.bin"\nLANG="C.UTF-8"\n' > "$work/environment.expected"
printf 'fixture credential one\n' > "$work/runtime/secrets/modular-mcp.env"
jq --arg prefix "$prefix" --arg environment "$work/runtime/environment" --arg signal "$work/restart" \
  '.prefix=$prefix | .environment_file=$environment | .restart_signal=$signal' \
  "$ROOT/installation/hart-server-modular.json" > "$work/selection.json"
printf 'active\n' > "$work/active"
printf 'original\n' > "$work/invocation"
printf '%s\n' "$prefix/releases/old" > "$work/running"
printf '0\n' > "$work/restarts"
cat > "$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == show && $2 == laplace-modular-mcp.service ]] || exit 90
if [[ -e "$ACTIVATION_FIXTURE/restart" ]]; then
  count=$(cat "$ACTIVATION_FIXTURE/restarts")
  count=$((count+1))
  printf '%s\n' "$count" > "$ACTIVATION_FIXTURE/restarts"
  printf 'invocation-%s\n' "$count" > "$ACTIVATION_FIXTURE/invocation"
  printf 'active\n' > "$ACTIVATION_FIXTURE/active"
  realpath -e -- "$ACTIVATION_FIXTURE/install with spaces/current" > "$ACTIVATION_FIXTURE/running"
  rm "$ACTIVATION_FIXTURE/restart"
fi
printf 'InvocationID=%s\nActiveState=%s\n' "$(cat "$ACTIVATION_FIXTURE/invocation")" "$(cat "$ACTIVATION_FIXTURE/active")"
SH
cat > "$work/bin/verify-runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --release && $3 == --output ]] || exit 91
release=$2 output=$4
[[ $(cat "$ACTIVATION_FIXTURE/running") == "$release" ]] || exit 92
[[ ${release##*/} != broken ]] || exit 67
if [[ -e "$ACTIVATION_FIXTURE/fail-once" ]]; then rm "$ACTIVATION_FIXTURE/fail-once"; exit 68; fi
[[ ! -e "$ACTIVATION_FIXTURE/fail-verification" ]] || exit 68
jq -n --arg release "$release" '{verified:true,release:$release}' > "$output"
SH
chmod +x "$work/bin/systemctl" "$work/bin/verify-runtime"
export PATH="$work/bin:$PATH"
activate() {
  mkdir "$work/$2"
  bash "$ROOT/installation/activate-modular.sh" "$work/selection.json" "$prefix/releases/$1" \
    "$work/$2" "$work/unit" "$work/environment.expected" -- "$work/bin/verify-runtime" < "$work/expected-unit"
}
cp "$work/unit" "$work/expected-unit"
activate old bootstrap
test "$(cat "$work/restarts")" = 1
stat -c '%d:%i:%z' "$prefix/current" "$prefix/.activation.json" > "$work/before"
activate old unchanged
stat -c '%d:%i:%z' "$prefix/current" "$prefix/.activation.json" > "$work/after"
diff -u "$work/before" "$work/after"
test "$(cat "$work/restarts")" = 1
jq -e '.action == "reused"' "$work/unchanged/activation.json" > /dev/null
echo 'PASS unchanged verified release preserves process, pointer and activation record'

printf 'service-recovered-itself\n' > "$work/invocation"
activate old recovered
test "$(cat "$work/restarts")" = 1
jq -e '.invocation == "service-recovered-itself" and .action == "reused"' "$work/recovered/activation.json" > /dev/null
echo 'PASS an independently recovered process is verified and retained on its unchanged release'

activate new changed
test "$(cat "$work/restarts")" = 2
test "$(realpath "$prefix/current")" = "$prefix/releases/new"
jq -e '.action == "activated"' "$work/changed/activation.json" > /dev/null
activate new changed-again
test "$(cat "$work/restarts")" = 2
echo 'PASS changed release activates once and its subsequent deployment reuses it'

printf 'inactive\n' > "$work/active"
activate new inactive
test "$(cat "$work/restarts")" = 3
echo 'PASS inactive service is activated even when the selected release is unchanged'

printf 'fixture credential two\n' > "$work/runtime/secrets/modular-mcp.env"
activate new credential-change
test "$(cat "$work/restarts")" = 4
echo 'PASS changed listener credentials require activation and verification'

touch "$work/fail-once"
activate new unhealthy
test "$(cat "$work/restarts")" = 5
echo 'PASS a failed current-service readback requires activation and a fresh successful verification'

if activate broken failed > "$work/failed.log" 2>&1; then echo 'FAIL bad runtime accepted' >&2; exit 1; fi
test "$(realpath "$prefix/current")" = "$prefix/releases/new"
test -f "$work/restart"
systemctl show laplace-modular-mcp.service > "$work/rollback-state"
test "$(cat "$work/running")" = "$prefix/releases/new"
test "$(cat "$work/restarts")" = 7
echo 'PASS failed activation restores the previous release and requests its restart'

count=$(cat "$work/restarts")
stat -c '%d:%i:%z' "$prefix/current" > "$work/before-refusal"
printf 'unexpected unit\n' > "$work/unit"
if activate old unit-drift > "$work/unit-drift.log" 2>&1; then echo 'FAIL unit drift accepted' >&2; exit 1; fi
cp "$work/expected-unit" "$work/unit"
printf 'OMP_NUM_THREADS="5"\n' > "$work/runtime/environment"
if activate old environment-drift > "$work/environment-drift.log" 2>&1; then echo 'FAIL environment drift accepted' >&2; exit 1; fi
cp "$work/environment.original" "$work/runtime/environment"
stat -c '%d:%i:%z' "$prefix/current" > "$work/after-refusal"
diff -u "$work/before-refusal" "$work/after-refusal"
test "$(cat "$work/restarts")" = "$count"
test ! -e "$work/restart"
echo 'PASS unit and environment drift fail before pointer changes or restart requests'

test -z "$(find "$work" -name '.unit.*' -o -name '.current.*' -o -name '.activation.????????' | head -1)"
echo 'PASS activation temporaries are removed'
