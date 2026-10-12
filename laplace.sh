#!/bin/bash
# Checkout convenience only. installation/install-client.py installs a standalone command.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec python3 "$here/installation/client.py" "$@"
