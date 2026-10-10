#!/usr/bin/env bash
set -euo pipefail
: "${TMPDIR:?build scratch required}"
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
before=$(sha256sum "$SECRETS_BACKUP_DIR"/vaultwarden/* "$SECRETS_BACKUP_DIR"/openbao/*)
for failure in renew save checksum missing-token; do
  export FAIL_AT=$failure
  if [[ $failure == checksum ]]; then
    printf 'corrupted\n' >> "$work/snapshot/state.bin"
    tar -C "$work/snapshot" -czf "$SNAPSHOT_FIXTURE" meta.json state.bin SHA256SUMS
  fi
  [[ $failure != missing-token ]] || rm "$work/token"
  if bash "$root/secrets/backup-secrets.sh" >> "$work/log" 2>&1; then echo "accepted failure: $failure"; exit 1; fi
  [[ $(sha256sum "$SECRETS_BACKUP_DIR"/vaultwarden/* "$SECRETS_BACKUP_DIR"/openbao/*) == "$before" ]]
  [[ -z $(find "$SECRETS_BACKUP_DIR" -maxdepth 1 -name '.pending.*' -print) ]]
done
! grep -q 'fixture-token-not-for-logs' "$work/log"
echo 'PASS restored SQLite fixture; private complete backups; renewal, snapshot, corruption and missing-credential failures preserve prior backups'
