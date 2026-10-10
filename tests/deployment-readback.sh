#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?use build scratch storage}"
fixture=$(mktemp -d "$TMPDIR/deployment-readback.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/src/Laplace-postgres"
cp "$root/verify.sh" "$fixture/verify.sh"
cp "$root/operation-lock.sh" "$fixture/operation-lock.sh"
printf "default_version = '1.12'\n" > "$fixture/src/Laplace-postgres/laplace.control"
cat > "$fixture/laplace.env" <<'ENV'
LAPLACE_WORK=$FIXTURE/work/$CASE
LAPLACE_LOCKS=$FIXTURE
LAPLACE_PROGRAM=$FIXTURE/bin/laplace
LAPLACE_PG_DIR=$FIXTURE
LAPLACE_SRC=$FIXTURE/src
LAPLACE_CONNINFO='dbname=fixture'
LAPLACE_TIER0=$FIXTURE/tier0
LAPLACE_HIGHWAY=$FIXTURE/highway
ENV
for f in tier0 highway highway.layout highway.keys; do printf 'artifact\n' > "$fixture/$f"; done
cat > "$fixture/bin/laplace" <<'STUB'
#!/bin/sh
case "$*" in
  'text a') printf 'tier 0 %064d\n' 1 ;;
  'highway --fingerprint') printf 'fingerprint %064d\n' 2 ;;
  *) exit 90 ;;
esac
STUB
cat > "$fixture/bin/psql" <<'STUB'
#!/bin/sh
version=1.12; t0=1; hw=2; schema=t
case "$CASE" in
  version) version=1.11;; tier0) t0=3;; highway) hw=4;; schema) schema=f;; error) exit 1;; absent) exit 0;;
esac
printf '%s|%064d|%064d|%s\n' "$version" "$t0" "$hw" "$schema"
STUB
chmod +x "$fixture/bin/psql" "$fixture/bin/laplace"
export FIXTURE="$fixture" GITHUB_STEP_SUMMARY=
for CASE in valid version tier0 highway schema error absent; do
  export CASE
  result=0
  bash "$fixture/verify.sh" deployment > "$fixture/output" 2>&1 || result=$?
  expected=1; [[ $CASE == valid ]] && expected=0
  [[ $result == "$expected" ]] || { cat "$fixture/output"; echo "unexpected result $result for $CASE"; exit 1; }
  if [[ $CASE != valid ]]; then grep -q '\*\*FAIL\*\*' "$fixture/output"; fi
  echo "PASS deployment readback $CASE (exit $result)"
done
