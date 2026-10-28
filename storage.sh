#!/usr/bin/env bash
# Operator and CI entry point; all deletion policy belongs to installation/storage.py.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/laplace.env"
operation=${1:-status}
shift || true
exec python3 "$here/installation/storage.py" "$operation" "$@"
