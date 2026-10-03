#!/bin/sh
# Laplace, from an empty server to a Laplace database ready to be loaded: the build, the perf-caches generated (tier 0
# and its flags once, the highway every time: it takes seconds), the grammars, the database with its extension and
# schema, and its status. No data is loaded here: loading is ingest.sh, an operation of its own on what this left
# (Laplace-Operations; the code is Laplace-Native, Laplace-postgres and Laplace-Engine beside it under $LAPLACE_SRC).
# Everything it does can be done again: what is built is not rebuilt, what is recorded is passed over by its bytes,
# and a run that was cut off is taken up by running it again.
#
#   ./deploy.sh                                      the database laplace.env names
#   LAPLACE_CONNINFO="... dbname=NAME" ./deploy.sh   another database; it is made if the server does not have it
#
# What it needs first: PostgreSQL 18 with PostGIS running, a role that may create databases and extensions, and the
# data under $LAPLACE_DATA (Operations: Setup, Builds). What each step said is kept in $LAPLACE_WORK/logs/deploy.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
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
log=$LAPLACE_WORK/logs/deploy/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$log"
step(){ name=$1; shift; echo; echo "=== $name   $(date -u +%H:%M:%S)"
        { "$@" 2>&1; echo $? > "$log/$name.exit"; } | grep --line-buffered -v "^OMP: " | tee "$log/$name.log"
        [ "$(cat "$log/$name.exit" 2>/dev/null)" = 0 ] || { echo "=== $name did not finish; what it said is in $log/$name.log"; exit 1; }; }

step build      "$here/build.sh" install
[ -s "$LAPLACE_TIER0" ] || step tier0 laplace tier0
[ -s "${LAPLACE_TIER0%.bin}.flags" ] || step flags laplace flags
step highway    laplace highway                                   # seconds; always current with the generator and the resources
[ -n "$(ls "$LAPLACE_GRAMMARS" 2>/dev/null)" ] || step grammars "$LAPLACE_SRC/Laplace-Engine/tools/build_grammars.sh" "$LAPLACE_GRAMMAR_SRC" "$LAPLACE_GRAMMARS"
step deploy     laplace deploy
step status     laplace status
ss -ltn 2>/dev/null | grep -q "0.0.0.0:5432\|\*:5432" || echo "
The server listens on localhost only: sudo ./setup.sh declares the machine, this among it (the one step that needs root)."
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
