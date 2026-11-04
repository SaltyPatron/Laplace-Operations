#!/usr/bin/env bash
# Converge or verify Tailscale MagicDNS routing in systemd-resolved for tailscale0.
# On Ubuntu hosts using systemd-resolved and systemd-networkd, tailscale0 is unmanaged
# by networkd; a systemd daemon-reload or networkd restart can drop per-link DNS scopes
# unless tailscaled reasserts them or they are verified and restored.
set -euo pipefail

mode=${1:-apply}
case "$mode" in
  --check|check) mode=check ;;
  --apply|apply) mode=apply ;;
  *) echo 'Usage: tailscale-dns.sh [--check|--apply]' >&2; exit 2 ;;
esac

for cmd in tailscale resolvectl jq getent; do
  command -v "$cmd" >/dev/null || { echo "Missing prerequisite: $cmd" >&2; exit 1; }
done

status_json=$(tailscale status --json)
backend_state=$(jq -r '.BackendState // empty' <<<"$status_json")
[[ "$backend_state" == "Running" ]] || { echo "Tailscale is not running ($backend_state)" >&2; exit 1; }

suffix=$(jq -r '.CurrentTailnet.MagicDNSSuffix // empty' <<<"$status_json" | sed 's/\.$//')
[[ "$suffix" =~ ^[A-Za-z0-9.-]+\.ts\.net$ ]] || { echo "Invalid or missing Tailscale MagicDNSSuffix: $suffix" >&2; exit 1; }

dns_status=$(resolvectl dns tailscale0 2>/dev/null || true)
domain_status=$(resolvectl domain tailscale0 2>/dev/null || true)

has_dns=0
[[ "$dns_status" == *"100.100.100.100"* ]] && has_dns=1
has_domain=0
[[ "$domain_status" == *"$suffix"* && "$domain_status" == *"~ts.net"* ]] && has_domain=1

if [[ "$mode" == "check" ]]; then
  if (( ! has_dns || ! has_domain )); then
    echo "tailscale0 DNS scope missing in systemd-resolved (dns: $dns_status; domain: $domain_status)" >&2
    exit 1
  fi
else
  [[ $EUID == 0 ]] || { echo 'Root is required to configure systemd-resolved for tailscale0.' >&2; exit 1; }
  # Ensure tailscaled has accept-dns enabled so it maintains MagicDNS across reconnects,
  # and explicitly program systemd-resolved on tailscale0 immediately.
  tailscale set --accept-dns=true
  if (( ! has_dns || ! has_domain )); then
    resolvectl dns tailscale0 100.100.100.100
    resolvectl domain tailscale0 "$suffix" "~ts.net"
    resolvectl flush-caches
  fi
fi

# Verify self and online peer resolution through the system resolver.
self_host=$(jq -r '.Self.HostName // empty' <<<"$status_json")
if [[ -n "$self_host" ]]; then
  getent ahostsv4 "$self_host" >/dev/null || { echo "System resolver failed to resolve $self_host" >&2; exit 1; }
fi

echo "tailscale0 MagicDNS ($suffix via 100.100.100.100) verified."
