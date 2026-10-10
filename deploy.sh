#!/bin/sh
# Build and deploy Laplace using independently prepared perf-cache artifacts.
# Generation, resource fetching and content admission are separate operations.
# Deployment builds the code, installs it, updates the database schema/settings and reports status.
#
#   ./deploy.sh                                      the database laplace.env names
#   LAPLACE_CONNINFO="... dbname=NAME" ./deploy.sh   another database; it is made if the server does not have it
#   ./deploy.sh drop                                 the database dropped first and made again, empty
#   ./deploy.sh as-is                                from the checkouts as they are, not brought to their upstream (after drop, with it)
#
# What it needs first: PostgreSQL 18 with PostGIS running, a role that may create databases and extensions, and the
# prepared perf-cache artifacts (README.md). What each step said is kept in $LAPLACE_WORK/logs/deploy.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
. "$here/operation-lock.sh"
laplace_host_lock exclusive

# Never from old sources. A person's checkouts under $LAPLACE_SRC are kept current by nothing: a deployment from ones
# days behind builds an old engine, reads old recipes (roots that are no longer where the data is) and writes a highway
# with most of its types gone over the one the machine runs on. Each repository this builds from is brought to its
# upstream first; one that cannot be (changed files, commits of its own, an upstream that cannot be fetched) stops the
# deployment before anything is built. A checkout on no branch is an exact revision someone chose (the pipeline's): it
# is left as it is. ./deploy.sh as-is deploys what is here, and says so.
asis=; for a in "$@"; do [ "$a" = as-is ] && asis=1; done
if [ -z "$asis" ] && [ -z "${LAPLACE_DEPLOY_CURRENT:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then   # in a workflow the revisions are the run's own, checked out for it
  moved=
  for r in Laplace-Operations Laplace-Native Laplace-postgres Laplace-Engine; do
    d=$LAPLACE_SRC/$r; [ "$r" = Laplace-Operations ] && d=$here
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { echo "$d is not a git checkout: nothing says what revision it is (./deploy.sh as-is deploys it anyway)"; exit 1; }
    b=$(git -C "$d" symbolic-ref -q --short HEAD) || { echo "  $r: at $(git -C "$d" rev-parse --short=12 HEAD), on no branch: an exact revision, left as it is"; continue; }
    git -C "$d" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 || { echo "$d: $b follows no upstream (./deploy.sh as-is deploys it anyway)"; exit 1; }
    [ -z "$(git -C "$d" status --porcelain --untracked-files=no)" ] || { echo "$d has changed files:"; git -C "$d" status --short --untracked-files=no | head -10; echo "commit or drop them, or ./deploy.sh as-is"; exit 1; }
    was=$(git -C "$d" rev-parse HEAD)
    git -C "$d" fetch -q || { echo "$d: its upstream could not be fetched, so whether it is current is not known (./deploy.sh as-is deploys it anyway)"; exit 1; }
    git -C "$d" merge -q --ff-only '@{upstream}' || { echo "$d: $b has commits its upstream does not (./deploy.sh as-is deploys it anyway)"; exit 1; }
    now=$(git -C "$d" rev-parse HEAD)
    if [ "$was" = "$now" ]; then echo "  $r: at its upstream, $(echo "$now" | cut -c1-12) ($b)"
    else echo "  $r: brought from $(echo "$was" | cut -c1-12) to $(echo "$now" | cut -c1-12) ($b)"; [ "$r" = Laplace-Operations ] && moved=1; fi
  done
  [ -z "$moved" ] || { echo "  this script changed: running what arrived"; LAPLACE_DEPLOY_CURRENT=1 exec "$here/deploy.sh" "$@"; }
elif [ -n "$asis" ]; then echo "  deploying what is here, not checked against any upstream (as-is)"; fi
# one deployment per database at a time, whoever runs it (the operator, an agent): the second says so and leaves
db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p'); [ -w "$LAPLACE_LOCKS" ] || LAPLACE_LOCKS=$LAPLACE_WORK   # before setup.sh: this user's own
umask 002                                                                      # what this makes, every operator of the group may take up
lock=$LAPLACE_LOCKS/deploy-${db:-default}.lock
if [ -e "$lock" ] && [ ! -w "$lock" ]; then                                    # left by another operator without group write: theirs while it runs, stale after
  p=$(cat "$lock.pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "a deployment of $db is already running (pid $p): this one leaves"; exit 3; fi
  rm -f "$lock" "$lock.pid"; fi
exec 9>>"$lock"
flock -n 9 || { echo "a deployment of $db is already running (pid $(cat "$lock.pid" 2>/dev/null)): this one leaves"; exit 3; }
echo $$ > "$lock.pid"
# never under an ingest: it rebuilds the program the ingest runs and changes the schema it writes into
ingest=$LAPLACE_LOCKS/ingest-${db:-default}.lock
if [ -e "$ingest" ] && ! flock -n "$ingest" true 2>/dev/null; then echo "an ingest of $db is running (pid $(cat "$ingest.pid" 2>/dev/null)): this deployment leaves: run it again when the ingest is done"; exit 3; fi
# Refuse missing artifacts before changing the database, including an explicit drop.
for artifact in "$LAPLACE_TIER0" "${LAPLACE_FLAGS:-${LAPLACE_TIER0%.bin}.flags}" "$LAPLACE_HIGHWAY" "$LAPLACE_HIGHWAY.layout" "$LAPLACE_HIGHWAY.keys"; do
  [ -s "$artifact" ] || { echo "missing deployment artifact: $artifact; prepare or install the perf-caches separately (README.md)"; exit 1; }
done
# ./deploy.sh drop: the database dropped and made again, empty, before it is deployed: by the role, which may drop
# databases, never by root (the cluster itself is setup.sh drop's, run by a person)
if [ "${1:-}" = drop ]; then
  [ -n "$db" ] && [ "$db" != postgres ] || { echo "deploy.sh drop: LAPLACE_CONNINFO names no database of Laplace's"; exit 2; }
  psql -X "$(echo "$LAPLACE_CONNINFO" | sed 's/dbname=[^ ]*/dbname=postgres/')" -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" || exit 1
  echo "=== $db dropped: it is made again below"
fi
log=$LAPLACE_WORK/logs/deploy/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$log"
step(){ name=$1; shift; echo; echo "=== $name   $(date -u +%H:%M:%S)"
        { "$@" 2>&1; echo $? > "$log/$name.exit"; } | grep --line-buffered -v "^OMP: " | tee "$log/$name.log"
        [ "$(cat "$log/$name.exit" 2>/dev/null)" = 0 ] || { echo "=== $name did not finish; what it said is in $log/$name.log"; exit 1; }; }

step tune-pg    bash "$here/tune-pg.sh"                          # the server's settings: apply, reload, check. a drift fails the deploy
step build      "$here/build.sh" install
[ -n "$(ls "$LAPLACE_GRAMMARS" 2>/dev/null)" ] || step grammars "$LAPLACE_SRC/Laplace-Engine/tools/build_grammars.sh" "$LAPLACE_GRAMMAR_SRC" "$LAPLACE_GRAMMARS"   # compiled grammar dependencies; no resource admission
step highway-fingerprint laplace highway --fingerprint
step deploy     laplace deploy
step status     laplace status
ss -ltn 2>/dev/null | grep -q "0.0.0.0:5432\|\*:5432" || echo "
The server listens on localhost only: sudo ./setup.sh declares the machine, this among it (the one step that needs root)."
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
