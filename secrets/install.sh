#!/usr/bin/env bash
# hart-server secrets stack: Vaultwarden (people) + OpenBao (machines).
# Both listen on 127.0.0.1 only; nginx publishes them LAN/Tailscale-only with the *.hartonomous.com wildcard.
#   sudo bash install.sh               install everything, test nginx config, do NOT reload nginx
#   sudo bash install.sh --reload      same, then reload nginx (wait until the Laplace deploys finish)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ $(hostname -s) == hart-server ]] || { echo 'This declares the existing hart-server secrets stack; wrong host.' >&2; exit 1; }
RELOAD=0; [[ "${1:-}" == "--reload" ]] && RELOAD=1

BAO_VER=2.7.1
VW_IMAGE=vaultwarden/server:1.37.4
BASE=/hosting
BACKUP=/backup/secrets
CERT=/etc/ssl/hartonomous.com
HERE=$(cd "$(dirname "$0")" && pwd)
for program in curl sqlite3 tar sha256sum nginx; do
  command -v "$program" >/dev/null || { echo "missing prerequisite: $program" >&2; exit 1; }
done
mountpoint -q /hosting && mountpoint -q /backup || { echo '/hosting and /backup must be mounted before setup' >&2; exit 1; }
[[ -s "$CERT/fullchain.pem" && -s "$CERT/privkey.pem" ]] || { echo 'Existing hartonomous.com certificate required' >&2; exit 1; }

echo "== 1. Docker (currently masked)"
systemctl unmask docker.service docker.socket containerd.service
systemctl enable --now containerd docker
docker info --format 'docker {{.ServerVersion}} ok'

echo "== 2. Vaultwarden"
install -d -m 700 "$BASE/vaultwarden/data"
if [[ ! -f "$BASE/vaultwarden/compose.yaml" ]]; then
  if [[ -e "$BASE/vaultwarden/data/db.sqlite3" ]]; then
    echo 'Vaultwarden data exists without compose.yaml; restore its configuration before setup.' >&2
    exit 1
  fi
cat > "$BASE/vaultwarden/compose.yaml" <<EOF
services:
  vaultwarden:
    image: $VW_IMAGE
    container_name: vaultwarden
    restart: unless-stopped
    ports: ["127.0.0.1:8222:80"]
    volumes: ["$BASE/vaultwarden/data:/data"]
    environment:
      DOMAIN: "https://vault.hartonomous.com"
      SIGNUPS_ALLOWED: "true"         # flip to false after the first account exists: sudo bash $HERE/lock-signups.sh
      INVITATIONS_ALLOWED: "false"
      SHOW_PASSWORD_HINT: "false"
      IP_HEADER: "X-Real-IP"
      LOG_FILE: "/data/vaultwarden.log"
      TZ: "America/Chicago"
EOF
fi
docker compose -f "$BASE/vaultwarden/compose.yaml" up -d
sleep 3; curl -fsS http://127.0.0.1:8222/alive && echo " vaultwarden alive"

echo "== 3. OpenBao $BAO_VER (native package, systemd)"
existing_bao_config=0
[[ ! -s /etc/openbao/openbao.hcl ]] || existing_bao_config=1
if command -v bao >/dev/null; then
  bao version | grep -F "v$BAO_VER" >/dev/null || { echo 'Installed Bao version differs; upgrade is a separate operation.' >&2; exit 1; }
else
install -d -m 700 /repos/build/secrets-setup
tmp=$(mktemp -d /repos/build/secrets-setup/install.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
curl -fsSLO "https://github.com/openbao/openbao/releases/download/v$BAO_VER/openbao_${BAO_VER}_linux_amd64.deb"
curl -fsSLO "https://github.com/openbao/openbao/releases/download/v$BAO_VER/checksums.txt"
grep " openbao_${BAO_VER}_linux_amd64.deb\$" checksums.txt | sha256sum -c -
apt-get install -y "./openbao_${BAO_VER}_linux_amd64.deb"
cd /; rm -rf "$tmp"
fi
install -d -m 700 -o openbao -g openbao "$BASE/openbao/data"
if [[ $existing_bao_config == 0 ]]; then
  [[ -z $(find "$BASE/openbao/data" -mindepth 1 -print -quit) ]] || { echo 'OpenBao data exists without configuration; restore its configuration.' >&2; exit 1; }
cat > /etc/openbao/openbao.hcl <<EOF
ui            = true
api_addr      = "https://openbao.hartonomous.com"
cluster_addr  = "http://127.0.0.1:8201"
disable_mlock = true   # required with integrated (raft) storage

storage "raft" {
  path    = "$BASE/openbao/data"
  node_id = "hart-server"
}

listener "tcp" {
  address         = "127.0.0.1:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable     = true          # loopback only; TLS terminates at nginx
  x_forwarded_for_authorized_addrs = "127.0.0.1"
}
EOF
chown root:openbao /etc/openbao/openbao.hcl; chmod 640 /etc/openbao/openbao.hcl
fi
systemctl enable --now openbao
sleep 3
export BAO_ADDR=http://127.0.0.1:8200
bao status || true   # exit 2 = sealed/uninitialized, expected here

echo "== 4. nginx sites (LAN + Tailscale only)"
cat > /etc/nginx/sites-available/secrets-lan <<'EOF'
# Vaultwarden + OpenBao. LAN (192.168.1.0/24) and Tailscale (100.64.0.0/10) only.
server {
    listen 192.168.1.2:443 ssl http2;
    server_name vault.hartonomous.com;
    ssl_certificate     /etc/ssl/hartonomous.com/fullchain.pem;
    ssl_certificate_key /etc/ssl/hartonomous.com/privkey.pem;
    allow 192.168.1.0/24; allow 100.64.0.0/10; allow 127.0.0.1; deny all;
    client_max_body_size 525M;
    location / {
        proxy_pass http://127.0.0.1:8222;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
server {
    listen 192.168.1.2:443 ssl http2;
    server_name openbao.hartonomous.com;
    ssl_certificate     /etc/ssl/hartonomous.com/fullchain.pem;
    ssl_certificate_key /etc/ssl/hartonomous.com/privkey.pem;
    allow 192.168.1.0/24; allow 100.64.0.0/10; allow 127.0.0.1; deny all;
    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/secrets-lan /etc/nginx/sites-enabled/secrets-lan
nginx -t
if [[ $RELOAD -eq 1 ]]; then systemctl reload nginx; echo "nginx reloaded"; else echo "nginx config OK, NOT reloaded (run: sudo systemctl reload nginx once the Laplace deploys finish)"; fi

echo "== 5. Nightly Vaultwarden backup -> $BACKUP (OpenBao snapshots get added after init)"
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

echo
echo 'Setup finished. Existing Bao initialization and identities are preserved; this script does not initialize or unseal it.'
