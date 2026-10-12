#!/usr/bin/env bash
set -euo pipefail
: "${TMPDIR:?build scratch required}"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "$TMPDIR/appdb-secrets.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export FIXTURE=$work
printf '{"role_id":"fixture-role","secret_id":"fixture-id"}\n' > "$work/credentials"
chmod 600 "$work/credentials"
printf 'substrate:5432:*:laplace:keep-this\n' > "$work/pgpass"
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/arguments"
[[ "$*" != *'--config -'* ]] || cat >/dev/null
url=${@: -1}
case $url in
  */auth/approle/login)
    [[ ${FAIL_AT:-} != login ]] || exit 22
    printf '{"auth":{"client_token":"fixture-session"}}\n' ;;
  */appdb)
    [[ ${FAIL_AT:-} != read ]] || exit 22
    cat "$FIXTURE/record" ;;
  */revoke-self) touch "$FIXTURE/revoked" ;;
  *) exit 90 ;;
esac
CURL
cat > "$work/bin/psql" <<'PSQL'
#!/usr/bin/env bash
[[ ${FAIL_AT:-} != database ]] || exit 2
[[ $PGPASSWORD == 's:ec\ret' ]] || exit 3
echo 1
PSQL
chmod +x "$work/bin/"*
export PATH=$work/bin:$PATH BAO_ADDR=https://fixture.invalid
printf '%s\n' '{"data":{"data":{"host":"hart-prod","port":"5432","role":"laplace","database":"laplace-app","password":"s:ec\\ret"}}}' > "$work/record"
run(){ bash "$root/secrets/appdb-sync.sh" hart-prod "$work/credentials" 127.0.0.1 "$work/pgpass" > "$work/log" 2>&1; }
run
[[ $(stat -c %a "$work/pgpass") == 600 ]]
grep -Fxq '127.0.0.1:5432:laplace-app:laplace:s\:ec\\ret' "$work/pgpass"
grep -Fxq 'substrate:5432:*:laplace:keep-this' "$work/pgpass"
[[ -e "$work/revoked" ]]
before=$(sha256sum "$work/pgpass")
run
[[ $(sha256sum "$work/pgpass") == "$before" ]]
for failure in login read database invalid-record; do
  export FAIL_AT=$failure
  [[ $failure != invalid-record ]] || printf '{"data":{"data":{}}}\n' > "$work/record"
  if run; then echo "accepted failure: $failure"; exit 1; fi
  [[ $(sha256sum "$work/pgpass") == "$before" ]]
done
! grep -Eq 'fixture-session|fixture-id|s:ec' "$work/arguments" "$work/log"
[[ -z $(find "$work" -maxdepth 1 -name '.bao-sync.*' -print) ]]
echo 'PASS authentication before publication, escaping, retained substrate credential, idempotence, session cleanup, failed auth/read/DB/schema preserve existing credentials'
