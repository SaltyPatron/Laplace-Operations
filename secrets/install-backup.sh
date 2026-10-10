#!/usr/bin/env bash
# Install and run the existing stores' backup job without reconfiguring their services.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run with sudo' >&2; exit 1; }
[[ $(hostname -s) == hart-server ]] || { echo 'This backup declaration belongs to hart-server' >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BACKUP=/backup/secrets
mountpoint -q /hosting && mountpoint -q /backup || { echo '/hosting and /backup must be mounted' >&2; exit 1; }
for program in bao sqlite3 tar sha256sum flock; do
  command -v "$program" >/dev/null || { echo "missing prerequisite: $program" >&2; exit 1; }
done
[[ -s /etc/openbao/snapshot.token && -r /etc/openbao/snapshot.token ]] || { echo 'Existing Bao snapshot credential required' >&2; exit 1; }
[[ -s /hosting/vaultwarden/data/db.sqlite3 ]] || { echo 'Existing Vaultwarden database required' >&2; exit 1; }
echo "=== Vaultwarden and OpenBao backups -> $BACKUP"
install -d -m 700 "$BACKUP"
install -m 750 "$HERE/backup-secrets.sh" /usr/local/sbin/backup-secrets
cat > /etc/systemd/system/backup-secrets.service <<'EOF'
[Unit]
Description=Back up Vaultwarden and OpenBao to /backup/secrets
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup-secrets
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
/usr/local/sbin/backup-secrets
