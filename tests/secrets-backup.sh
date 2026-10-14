#!/usr/bin/env bash
set -euo pipefail
: "${TMPDIR:=${RUNNER_TEMP:-/tmp}}"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "$TMPDIR/secrets-backup.XXXXXX")
trap 'rm -rf "$work"' EXIT
export SECRETS_BACKUP_DIR=$work/backup VAULTWARDEN_DATA_DIR=$work/data BAO_SNAPSHOT_TOKEN_FILE=$work/token
mkdir -p "$work/bin" "$work/snapshot" "$VAULTWARDEN_DATA_DIR"
sqlite3 "$VAULTWARDEN_DATA_DIR/db.sqlite3" 'CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES("retained");'
printf 'fixture-token-not-for-logs\n' > "$work/token"
printf '{}\n' > "$work/snapshot/meta.json"
printf 'encrypted-state-fixture\n' > "$work/snapshot/state.bin"
(cd "$work/snapshot" && sha256sum meta.json state.bin > SHA256SUMS && tar -czf "$work/snapshot.tgz" meta.json state.bin SHA256SUMS)
cp "$work/snapshot.tgz" "$work/valid-snapshot.tgz"
cp "$VAULTWARDEN_DATA_DIR/db.sqlite3" "$work/valid-db.sqlite3"
export SNAPSHOT_FIXTURE=$work/snapshot.tgz
cat > "$work/bin/bao" <<'BAO'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'token renew') [[ ${FAIL_AT:-} != renew ]] ;;
  'operator raft snapshot save '*)
    [[ ${FAIL_AT:-} != save ]] || exit 1
    cp "$SNAPSHOT_FIXTURE" "$5" ;;
  *) exit 90 ;;
esac
BAO
chmod +x "$work/bin/bao"
export PATH=$work/bin:$PATH
bash "$root/secrets/backup-secrets.sh" > "$work/log" 2>&1
[[ $(find "$SECRETS_BACKUP_DIR" -name 'vw-*.tar.gz' | wc -l) == 1 ]]
[[ $(find "$SECRETS_BACKUP_DIR" -name 'bao-*.snap' | wc -l) == 1 ]]
mkdir "$work/restore"
tar -xzf "$SECRETS_BACKUP_DIR"/vaultwarden/vw-*.tar.gz -C "$work/restore"
[[ $(sqlite3 "$work/restore/db.sqlite3" 'SELECT value FROM fixture;') == retained ]]
for file in "$SECRETS_BACKUP_DIR"/vaultwarden/* "$SECRETS_BACKUP_DIR"/openbao/*; do [[ $(stat -c %a "$file") == 600 ]]; done
sha256sum "$SECRETS_BACKUP_DIR"/vaultwarden/* "$SECRETS_BACKUP_DIR"/openbao/* > "$work/previous.sha256"
failures=0
for failure in renew save checksum missing-token missing-database corrupt-database; do
  cp "$work/valid-snapshot.tgz" "$SNAPSHOT_FIXTURE"
  cp "$work/valid-db.sqlite3" "$VAULTWARDEN_DATA_DIR/db.sqlite3"
  printf 'fixture-token-not-for-logs\n' > "$work/token"
  vaultwarden_before=$(find "$SECRETS_BACKUP_DIR/vaultwarden" -name 'vw-*.tar.gz' | wc -l)
  openbao_before=$(find "$SECRETS_BACKUP_DIR/openbao" -name 'bao-*.snap' | wc -l)
  export FAIL_AT=$failure
  if [[ $failure == checksum ]]; then
    printf 'corrupted\n' >> "$work/snapshot/state.bin"
    tar -C "$work/snapshot" -czf "$SNAPSHOT_FIXTURE" meta.json state.bin SHA256SUMS
  fi
  [[ $failure != missing-token ]] || rm "$work/token"
  [[ $failure != missing-database ]] || rm "$VAULTWARDEN_DATA_DIR/db.sqlite3"
  [[ $failure != corrupt-database ]] || printf 'not SQLite\n' > "$VAULTWARDEN_DATA_DIR/db.sqlite3"
  if bash "$root/secrets/backup-secrets.sh" >> "$work/log" 2>&1; then echo "accepted failure: $failure"; exit 1; fi
  sha256sum --check --status "$work/previous.sha256"
  vaultwarden_after=$(find "$SECRETS_BACKUP_DIR/vaultwarden" -name 'vw-*.tar.gz' | wc -l)
  openbao_after=$(find "$SECRETS_BACKUP_DIR/openbao" -name 'bao-*.snap' | wc -l)
  if [[ $failure == *database ]]; then
    [[ $vaultwarden_after == "$vaultwarden_before" && $openbao_after == "$((openbao_before+1))" ]]
  else
    [[ $vaultwarden_after == "$((vaultwarden_before+1))" && $openbao_after == "$openbao_before" ]]
  fi
  failures=$((failures+1))
  [[ $(jq -s '[.[] | select(.complete == false)] | length' "$SECRETS_BACKUP_DIR"/receipts/*.json) == "$failures" ]]
  [[ -z $(find "$SECRETS_BACKUP_DIR" -maxdepth 1 -name '.pending.*' -print) ]]
  echo "$failure: failing run retained the verified other store and all preceding backups"
done
unset FAIL_AT
cp "$work/valid-db.sqlite3" "$VAULTWARDEN_DATA_DIR/db.sqlite3"
bash "$root/secrets/backup-secrets.sh" >> "$work/log" 2>&1
[[ $(jq -s '[.[] | select(.complete == true)] | length' "$SECRETS_BACKUP_DIR"/receipts/*.json) == 2 ]]
for archive in "$SECRETS_BACKUP_DIR"/vaultwarden/vw-*.tar.gz; do
  tar -xzf "$archive" -C "$work/restore"
  [[ $(sqlite3 "$work/restore/db.sqlite3" 'SELECT value FROM fixture;') == retained ]]
done
for file in "$SECRETS_BACKUP_DIR"/vaultwarden/* "$SECRETS_BACKUP_DIR"/openbao/* "$SECRETS_BACKUP_DIR"/receipts/*; do [[ $(stat -c %a "$file") == 600 ]]; done
if grep -q 'fixture-token-not-for-logs' "$work/log"; then echo 'Snapshot credential leaked into output' >&2; exit 1; fi
echo 'PASS independent private backups; restored every SQLite archive; six failures retain the healthy store; recovery publishes a complete pair; no token disclosure'
