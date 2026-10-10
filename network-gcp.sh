#!/usr/bin/env bash
# Tailscale peer transport for the existing Laplace VM tags. This does not start instances or expose application ports.
set -euo pipefail
mode=${1:-check}
project=${LAPLACE_GCP_PROJECT:?set LAPLACE_GCP_PROJECT}
network=${LAPLACE_GCP_NETWORK:-default}
tags=${LAPLACE_GCP_TAILSCALE_TAGS:-hart-cloud,hart-prod}
sources=${LAPLACE_GCP_TAILSCALE_SOURCES:-0.0.0.0/0}
rule=laplace-tailscale-direct
case "$mode" in check|apply) ;; *) echo 'usage: network-gcp.sh [check|apply]' >&2; exit 2 ;; esac

exists=$(gcloud compute firewall-rules list --project="$project" --filter="name=$rule" --format='value(name)')
if [[ -z "$exists" ]]; then
  if [[ "$mode" == check ]]; then echo "$rule is missing" >&2; exit 1; fi
  gcloud compute firewall-rules create "$rule" --project="$project" --network="$network" \
    --direction=INGRESS --priority=1000 --allow=udp:41641 --source-ranges="$sources" --target-tags="$tags" \
    --description='Encrypted Tailscale peer transport for Laplace; application ports remain private.' --quiet
fi
current=$(gcloud compute firewall-rules describe "$rule" --project="$project" --format=json)
matches() {
  jq -e --arg network "$network" --arg tags "$tags" --arg sources "$sources" '
    (.network | endswith("/networks/" + $network)) and .direction == "INGRESS" and
    (.disabled != true) and .priority == 1000 and
    .allowed == [{"IPProtocol":"udp","ports":["41641"]}] and
    ((.targetTags | sort) == ($tags | split(",") | sort)) and
    ((.sourceRanges | sort) == ($sources | split(",") | sort))' <<< "$current" > /dev/null
}
if ! matches; then
  if [[ "$mode" == check ]]; then echo "$rule differs from the declaration" >&2; exit 1; fi
  # Network and direction are immutable. Do not replace a same-named rule in another scope.
  jq -e --arg network "$network" '(.network | endswith("/networks/" + $network)) and .direction == "INGRESS"' <<< "$current" > /dev/null
  gcloud compute firewall-rules update "$rule" --project="$project" --priority=1000 \
    --allow=udp:41641 --source-ranges="$sources" --target-tags="$tags" --no-disabled --quiet
  current=$(gcloud compute firewall-rules describe "$rule" --project="$project" --format=json)
  matches
fi
echo "$rule verified: $network, tags $tags, UDP 41641 from $sources"
