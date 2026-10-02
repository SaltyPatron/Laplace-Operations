#!/bin/sh
# The ingest: the sources, in the order they go in, into the database laplace.env names. An operation of its own on a
# machine that is built and deployed (deploy.sh): it builds nothing, installs nothing and makes no database. What is
# recorded already is passed over by its trunk, so a run that was cut off is taken up by running it again.
#
#   ./ingest.sh                                  every source in recipes/order
#   ./ingest.sh open-english-wordnet verbnet     these sources, in the order given
#
# One ingest per database at a time. What each step said is kept in $LAPLACE_WORK/logs/ingest-runs.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
# one ingest per database at a time, whoever runs it (the operator, an agent): the second says so and leaves
db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p'); [ -w "$LAPLACE_LOCKS" ] || LAPLACE_LOCKS=$LAPLACE_WORK   # before setup.sh: this user's own
umask 002                                                                      # what this makes, every operator of the group may take up
lock=$LAPLACE_LOCKS/ingest-${db:-default}.lock
if [ -e "$lock" ] && [ ! -w "$lock" ]; then                                    # left by another operator without group write: theirs while it runs, stale after
  p=$(cat "$lock.pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "an ingest of $db is already running (pid $p): this one leaves"; exit 3; fi
  rm -f "$lock" "$lock.pid"; fi
exec 9>>"$lock"
flock -n 9 || { echo "an ingest of $db is already running (pid $(cat "$lock.pid" 2>/dev/null)): this one leaves"; exit 3; }
echo $$ > "$lock.pid"
log=$LAPLACE_WORK/logs/ingest-runs/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$log"
step(){ name=$1; shift; echo; echo "=== $name   $(date -u +%H:%M:%S)"
        { "$@" 2>&1; echo $? > "$log/$name.exit"; } | grep --line-buffered -v "^OMP: " | tee "$log/$name.log"
        [ "$(cat "$log/$name.exit" 2>/dev/null)" = 0 ] || { echo "=== $name did not finish; what it said is in $log/$name.log"; exit 1; }; }

command -v laplace >/dev/null || { echo "no laplace program on the path: deploy.sh builds it"; exit 1; }
[ -s "$LAPLACE_TIER0" ] && [ -s "$LAPLACE_HIGHWAY" ] || { echo "no perf-caches at $LAPLACE_TIER0: deploy.sh generates them"; exit 1; }
# shellcheck disable=SC2086
step ingest     laplace ingest ${*:-$LAPLACE_SOURCES}             # the sources named, or every source in order
step status     laplace status
step bench      laplace bench
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
