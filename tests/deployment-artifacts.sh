#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${TMPDIR:?use build scratch storage}"
work=$(mktemp -d "$TMPDIR/deployment-artifacts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/locks" "$work/work" "$work/grammars" "$work/installation"
cp "$ROOT/deploy.sh" "$work/deploy.sh"
cp "$ROOT/operation-lock.sh" "$work/operation-lock.sh"
cp "$ROOT/machine-env.py" "$work/machine-env.py"
cp "$ROOT/installation/modular.py" "$ROOT/installation/database.py" "$work/installation/"
printf '' > "$work/machine.env"
printf 'grammar\n' > "$work/grammars/fixture"
cat > "$work/laplace.env" <<'ENV'
export LAPLACE_CONNINFO='dbname=fixture'
export LAPLACE_TIER0="$FIXTURE/tier0.bin" LAPLACE_HIGHWAY="$FIXTURE/tier0.highway"
export LAPLACE_WORK="$FIXTURE/work" LAPLACE_LOCKS="$FIXTURE/locks"
export LAPLACE_GRAMMARS="$FIXTURE/grammars" LAPLACE_SRC="$FIXTURE/src"
export LAPLACE_MACHINE_ENV="$FIXTURE/machine.env" LAPLACE_MODULAR_MANIFEST="${FIXTURE_MANIFEST:-}"
export PATH="$FIXTURE/bin:$PATH"
ENV
for command in tune-pg.sh build.sh; do
  cat > "$work/$command" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALL_LOG"
STUB
  chmod +x "$work/$command"
done
cat > "$work/bin/laplace" <<'STUB'
#!/bin/sh
printf 'laplace %s\n' "$*" >> "$CALL_LOG"
case "$*" in 'highway --fingerprint'|'deploy --configure-server-cache'|deploy|status) exit 0;; *) exit 90;; esac
STUB
cat > "$work/bin/psql" <<'STUB'
#!/bin/sh
if [ "${ALLOW_GRANTS:-}" = 1 ]; then cat >/dev/null; printf 'modular grants\n' >> "$CALL_LOG"; exit 0; fi
printf 'UNEXPECTED database mutation\n' >> "$CALL_LOG"
exit 91
STUB
chmod +x "$work/bin/laplace" "$work/bin/psql"
export FIXTURE="$work" CALL_LOG="$work/calls"
artifacts=(tier0.bin tier0.flags tier0.flags.layout tier0.highway)
for artifact in "${artifacts[@]}"; do printf 'prepared\n' > "$work/$artifact"; done
bash "$work/deploy.sh" as-is > "$work/output" 2>&1 || { cat "$work/output"; exit 1; }
cat > "$work/expected" <<'EXPECTED'
tune-pg.sh 
build.sh install
laplace highway --fingerprint
laplace deploy --configure-server-cache
laplace status
EXPECTED
diff -u "$work/expected" "$CALL_LOG"
echo 'PASS ordinary deployment consumes artifacts without generation, fetch or admission'
python3 - "$ROOT/installation/hart-server-modular.json" "$work" <<'PY'
import json,pathlib,socket,sys
root=pathlib.Path(sys.argv[2]); config=json.load(open(sys.argv[1]))
config.update(host=socket.gethostname().lower(), database='fixture', pgbin=str(root/'bin'),
              installed_config=str(root/'installation/selected.json'))
(root/'installation/selected.json').write_text(json.dumps(config))
PY
: > "$CALL_LOG"
FIXTURE_MANIFEST="$work/installation/selected.json" ALLOW_GRANTS=1 bash "$work/deploy.sh" as-is > "$work/output" 2>&1 || { cat "$work/output"; exit 1; }
sed 's/laplace deploy --configure-server-cache/laplace deploy\nmodular grants/' "$work/expected" > "$work/expected-modular"
diff -u "$work/expected-modular" "$CALL_LOG"
echo 'PASS declared modular database preserves its cache bindings and uses its selected installation for grants'
for artifact in "${artifacts[@]}"; do
  mv "$work/$artifact" "$work/held"
  : > "$CALL_LOG"
  if bash "$work/deploy.sh" drop as-is > "$work/output" 2>&1; then echo "accepted missing $artifact"; exit 1; fi
  [[ ! -s "$CALL_LOG" ]]
  grep -Eq 'missing deployment artifact' "$work/output"
  mv "$work/held" "$work/$artifact"
  echo "PASS missing $artifact blocks changes before explicit drop"
done
