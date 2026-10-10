#!/usr/bin/env bash
# Inputs are installation declarations and the caller's GitHub run identity.
set -euo pipefail
: "${PROJECT:?}" "${INSTANCE:?}" "${ZONE:?}" "${OPERATION:?}" "${MINUTES:?}"
: "${GITHUB_REPOSITORY_ID:?}" "${GITHUB_RUN_ID:?}"
[[ "$OPERATION" = acquire || "$OPERATION" = release ]]
[[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 && "$MINUTES" -le 360 ]]
[[ "$GITHUB_REPOSITORY_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]
lease_key="laplace-lease-${GITHUB_REPOSITORY_ID}-${GITHUB_RUN_ID}"
target=("$INSTANCE" --project="$PROJECT" --zone="$ZONE" --quiet)
if [[ "$OPERATION" = release ]]; then
  gcloud compute instances remove-metadata "${target[@]}" --keys="$lease_key"
  exit 0
fi
gcloud compute instances add-metadata "${target[@]}" --metadata "$lease_key=$GITHUB_RUN_ID $(( $(date +%s) + MINUTES * 60 ))"
for attempt in $(seq 1 30); do
  state=$(gcloud compute instances describe "${target[@]}" --format='value(status)')
  case "$state" in
    RUNNING) exit 0 ;;
    TERMINATED) gcloud compute instances start "${target[@]}" ;;
    SUSPENDED) gcloud compute instances resume "${target[@]}" ;;
    STOPPING|STAGING|PROVISIONING|SUSPENDING|REPAIRING) ;;
    *) echo "Unsupported instance state: $state" >&2; exit 1 ;;
  esac
  sleep 5
done
echo 'Cloud worker did not become ready' >&2
exit 1
