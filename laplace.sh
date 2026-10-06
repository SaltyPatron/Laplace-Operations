#!/bin/bash
# laplace for an operator on the deployment target: the program the last deployment built, run with the code, recipes,
# perf-caches and environment that deployment used (the Operations runner's checkouts, its runner/.env and laplace.env),
# so what an operator runs by hand is exactly what was deployed. Installed as the operator's own command:
#   install -m 755 laplace.sh ~/.local/bin/laplace
# LAPLACE_DEPLOYMENT names another runner's directory ($LAPLACE_AGENT_HOME/Laplace-Operations by default).
R=${LAPLACE_DEPLOYMENT:-/var/lib/agents/laplace-runner/Laplace-Operations}
W=$R/work/Laplace-Operations/Laplace-Operations
[ -r "$R/runner/.env" ] && [ -r "$W/Laplace-Operations/laplace.env" ] || { echo "laplace: no deployment at $R (agents.sh makes the runner; a push to Laplace-Operations' main deploys)" >&2; exit 1; }
set -a; . "$R/runner/.env"; set +a
export LAPLACE_SRC=$W
. "$W/Laplace-Operations/laplace.env"
exec "$LAPLACE_BUILD/Laplace-Engine/icx-release/laplace" "$@"
