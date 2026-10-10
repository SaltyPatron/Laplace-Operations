#!/usr/bin/env bash
# Publish a complete pair only after both stores have produced readable backups.
set -euo pipefail
set +x
umask 077
DEST=${SECRETS_BACKUP_DIR:-/backup/secrets}
VW=${VAULTWARDEN_DATA_DIR:-/hosting/vaultwarden/data}
TOKEN=${BAO_SNAPSHOT_TOKEN_FILE:-/etc/openbao/snapshot.token}
export BAO_ADDR=${BAO_ADDR:-http://127.0.0.1:8200}
[[ -s "$TOKEN" && -r "$TOKEN" ]] || { echo 'OpenBao snapshot credential missing or unreadable; backup incomplete' >&2; exit 1; }
[[ -s "$VW/db.sqlite3" ]] || { echo 'Vaultwarden database missing; backup incomplete' >&2; exit 1; }
if [[ $DEST == /backup/secrets ]]; then
  mountpoint -q /backup || { echo '/backup is not mounted; refusing backup to system disk' >&2; exit 1; }
fi
install -d -m 700 "$DEST" "$DEST/vaultwarden" "$DEST/openbao"
exec 9>"$DEST/.backup.lock"
flock -n 9 || { echo 'A secrets backup is already running' >&2; exit 1; }
work=$(mktemp -d "$DEST/.pending.XXXXXX")
trap 'rm -rf "$work"; unset BAO_TOKEN' EXIT
mkdir "$work/vaultwarden"
sqlite3 "$VW/db.sqlite3" ".backup '$work/vaultwarden/db.sqlite3'"
[[ $(sqlite3 "$work/vaultwarden/db.sqlite3" 'PRAGMA quick_check;') == ok ]] || { echo 'Vaultwarden backup integrity check failed' >&2; exit 1; }
shopt -s nullglob
for file in "$VW"/rsa_key* "$VW/attachments" "$VW/sends" "$VW/config.json"; do
  [[ ! -e "$file" ]] || cp -a "$file" "$work/vaultwarden/"
done
tar -C "$work/vaultwarden" -czf "$work/vaultwarden.tar.gz" .
export BAO_TOKEN=$(cat "$TOKEN")
bao token renew >/dev/null
bao operator raft snapshot save "$work/openbao.snap"
mkdir "$work/openbao"
tar -xzf "$work/openbao.snap" -C "$work/openbao" meta.json state.bin SHA256SUMS
awk 'NF != 2 || ($2 != "meta.json" && $2 != "state.bin") { exit 1 }
     { seen[$2]++ } END { if (seen["meta.json"] != 1 || seen["state.bin"] != 1) exit 1 }' "$work/openbao/SHA256SUMS"
(cd "$work/openbao" && sha256sum -c SHA256SUMS >/dev/null)
unset BAO_TOKEN
stamp=$(date -u +%Y%m%dT%H%M%S)-$$
chmod 600 "$work/vaultwarden.tar.gz" "$work/openbao.snap"
mv "$work/vaultwarden.tar.gz" "$DEST/vaultwarden/vw-$stamp.tar.gz"
mv "$work/openbao.snap" "$DEST/openbao/bao-$stamp.snap"
find "$DEST/vaultwarden" -maxdepth 1 -name 'vw-*.tar.gz' -type f -mtime +30 -delete
find "$DEST/openbao" -maxdepth 1 -name 'bao-*.snap' -type f -mtime +30 -delete
echo "backup-secrets: Vaultwarden integrity check and Bao snapshot checksums passed ($stamp)"
