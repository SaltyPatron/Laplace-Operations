#!/usr/bin/env bash
# Install and run the existing stores' backup job without reconfiguring their services.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
[[ $(hostname -s) == hart-server ]] || { echo 'This backup declaration belongs to hart-server' >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BACKUP=${SECRETS_BACKUP_DIR:-/backup/secrets}
VW=${VAULTWARDEN_DATA_DIR:-/hosting/vaultwarden/data}
TOKEN=${BAO_SNAPSHOT_TOKEN_FILE:-/etc/openbao/snapshot.token}
BACKUP_MOUNT=${SECRETS_BACKUP_MOUNT:-/backup}
DATA_MOUNT=${SECRETS_DATA_MOUNT:-/hosting}
mountpoint -q "$DATA_MOUNT" && mountpoint -q "$BACKUP_MOUNT" || { echo 'Declared secrets data and backup volumes must be mounted' >&2; exit 1; }
for program in bao sqlite3 tar sha256sum flock; do
  command -v "$program" >/dev/null || { echo "missing prerequisite: $program" >&2; exit 1; }
done
[[ -s "$TOKEN" && -r "$TOKEN" ]] || { echo 'Existing Bao snapshot credential required' >&2; exit 1; }
[[ -s "$VW/db.sqlite3" ]] || { echo 'Existing Vaultwarden database required' >&2; exit 1; }
echo "=== Vaultwarden and OpenBao backups -> $BACKUP"
install -d -m 700 "$BACKUP"
install -m 750 "$HERE/backup-secrets.sh" /usr/local/sbin/backup-secrets
install -d -m 755 /usr/local/libexec
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'export SECRETS_BACKUP_DIR=%q VAULTWARDEN_DATA_DIR=%q BAO_SNAPSHOT_TOKEN_FILE=%q BAO_ADDR=%q\n' \
    "$BACKUP" "$VW" "$TOKEN" "${BAO_ADDR:-http://127.0.0.1:8200}"
  printf 'mountpoint -q %q\nmountpoint -q %q\n' "$BACKUP_MOUNT" "$DATA_MOUNT"
  printf 'exec /usr/local/sbin/backup-secrets\n'
} > /usr/local/libexec/laplace-secrets-backup
chmod 750 /usr/local/libexec/laplace-secrets-backup
cat > /etc/systemd/system/backup-secrets.service <<'EOF'
[Unit]
Description=Back up Vaultwarden and OpenBao to the declared backup volume
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/laplace-secrets-backup
EOF
cat > /etc/systemd/system/backup-secrets.timer <<'EOF'
[Unit]
Description=Nightly secrets backup
[Timer]
OnCalendar=*-*-* 03:15
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now backup-secrets.timer
/usr/local/libexec/laplace-secrets-backup
