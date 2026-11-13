#!/usr/bin/env bash
# verify.sh reads and tests: a read proves itself by what it printed, an empty database is said to be empty, and a host
# that declares a modular runtime fails, never skips, when it cannot check it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?use build scratch storage}"
fixture=$(mktemp -d "$TMPDIR/deployment-reads.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/installation" "$fixture/src/Laplace-postgres/tests" "$fixture/src/Laplace-Engine/tests/deployed" \
  "$fixture/src/Laplace-MCP/tests/deployed" "$fixture/prefix/current/bin"
cp "$root/verify.sh" "$root/operation-lock.sh" "$fixture/"
cat > "$fixture/laplace.env" <<'ENV'
LAPLACE_WORK=$FIXTURE/work/$CASE
LAPLACE_LOCKS=$FIXTURE
LAPLACE_PROGRAM=$FIXTURE/bin/laplace
LAPLACE_PG_DIR=$FIXTURE
LAPLACE_SRC=$FIXTURE/src
LAPLACE_BUILD=$FIXTURE/build
LAPLACE_CONNINFO='dbname=fixture'
ENV
cat > "$fixture/bin/laplace" <<'STUB'
#!/bin/sh
case "$1" in
  status) printf 'database   fixture\n' ;;
  text) [ "$CASE" = noentity ] && { echo 'nothing'; exit 0; }
        printf 'entity     %032d   tier 1   (0.1, 0.2, 0.3, 0.4)\n' 7 ;;
  hop) [ "$CASE" = nocount ] && exit 0
       n=3; case "$CASE" in empty|unattested) n=0 ;; esac; printf 'entity x\n\nattested: %s claims\n' "$n" ;;
  translate) printf '\n3 steps, each one set   total 1.0 ms\n' ;;
  *) exit 90 ;;
esac
STUB
cat > "$fixture/bin/psql" <<'STUB'
#!/bin/sh
case "$CASE" in psqlerror) echo 'connection refused' >&2; exit 2 ;; empty) echo f ;; *) echo t ;; esac
STUB
cat > "$fixture/installation/modular.py" <<'STUB'
import os, sys
case = os.environ['CASE']
if case == 'selecterror':
    sys.exit('declaration is invalid')
if case == 'undeclared':
    print('')
elif '--database' in sys.argv and case == 'otherdatabase':
    print('')
else:
    print(os.environ['FIXTURE'] + '/manifest.json')
STUB
printf '{"prefix": "%s/prefix"}\n' "$fixture" > "$fixture/manifest.json"
printf '#!/bin/sh\nexit 0\n' > "$fixture/prefix/current/bin/lpm"
for runner in Laplace-postgres/tests/deployed.sh Laplace-Engine/tests/deployed/run.sh Laplace-MCP/tests/deployed/run.sh; do
  printf 'echo "check passed by %s"\n' "$runner" > "$fixture/src/$runner"
done
chmod +x "$fixture/bin/psql" "$fixture/bin/laplace" "$fixture/prefix/current/bin/lpm"
export FIXTURE="$fixture" GITHUB_STEP_SUMMARY=
check(){ local mode=$1 CASE=$2 expected=$3 says=$4 result=0; export CASE
  bash "$fixture/verify.sh" "$mode" > "$fixture/output" 2>&1 || result=$?
  [[ $result == "$expected" ]] || { cat "$fixture/output"; echo "unexpected result $result for $mode $CASE"; exit 1; }
  grep -q -- "$says" "$fixture/output" || { cat "$fixture/output"; echo "$mode $CASE did not say: $says"; exit 1; }
  echo "PASS $mode $CASE (exit $result)"; }
check reads held 0 'ok: laplace hop -n 5 dog: 3 claims attested'
check reads empty 0 'EMPTY'
check reads unattested 1 'none about dog was read'
check reads nocount 1 'printed no attested count'
check reads noentity 1 'named no entity'
check reads psqlerror 1 'whether it holds attestations'
check tests declared 0 'Laplace-MCP: check passed'
check tests undeclared 0 'SKIPPED: this host declares no modular runtime'
check tests otherdatabase 1 'for another database than fixture'
check tests selecterror 1 'modular declaration selection failed'
rm "$fixture/prefix/current/bin/lpm"
check tests declared 1 'no release is installed'
