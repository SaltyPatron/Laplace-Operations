#!/bin/sh
# The reseed policy of a deployment target: what a database was seeded from, kept on the database itself, and whether
# the code now checked out would seed it differently. A database's content is what Laplace-Native, Laplace-Engine
# (its source and recipes), Laplace-postgres and Operations' floating-point contract made of the data; documentation,
# workflows, tests and the firmware (which reads, never writes, the content) are not. The stamp is a hash of those trees.
#
#   ./seed-stamp.sh show       the stamp of the code under $LAPLACE_SRC, and of each repository
#   ./seed-stamp.sh recorded   what the database says it was seeded from
#   ./seed-stamp.sh decide     drop=, ingest= and why (to $GITHUB_OUTPUT too, in a workflow)
#   ./seed-stamp.sh pending    the database dropped for a reseed: the stamp it is being seeded to, not yet done
#   ./seed-stamp.sh seeded     the ingest finished: the database holds this stamp
#
# The stamp is a comment on the database (COMMENT ON DATABASE), so it goes with the database when it is dropped. A
# database with no stamp, or another, is dropped and seeded again when LAPLACE_RESEED=auto (laplace.env); with
# LAPLACE_RESEED=never a deployment only says so. A reseed cut off half way leaves "pending" with its stamp, and the
# next deployment with the same stamp takes the ingest up again without a drop (what is recorded is passed over).
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p')
admin=$(echo "$LAPLACE_CONNINFO" | sed 's/dbname=[^ ]*/dbname=postgres/')
# a repository's tree, less what does not bear on content: its hash, and its commit
tree(){ r=$LAPLACE_SRC/$1; [ -d "$r/.git" ] || [ -f "$r/.git" ] || { echo "none none"; return; }
  if [ "$1" = Laplace-Operations ]; then keep='	(toolchain|math|patches)/|	dependencies\.tsv$'; else keep='.'; fi
  h=$(git -c safe.directory='*' -C "$r" ls-tree -r HEAD | grep -E "$keep" | grep -v -E '	(docs|\.github|tests?|firmware)/|\.md$' | sha256sum | cut -c1-16)
  echo "$h $(git -c safe.directory='*' -C "$r" rev-parse --short=12 HEAD)"; }
stamp(){ for r in Laplace-Native Laplace-Engine Laplace-postgres Laplace-Operations; do echo "$r $(tree $r)"; done; }
want(){ stamp | awk '{print $2}' | sha256sum | cut -c1-16; }
commits(){ stamp | awk '{split($1, n, "-"); printf "%s=%s ", tolower(n[2]), $3}'; }
# A server that cannot be asked is not a server without the database: its own error is said and the policy stops.
ask(){ local out; out=$(psql -X "$admin" -v ON_ERROR_STOP=1 -Atc "$1" 2>&1) || { echo "seed-stamp: cannot ask the server about $db: $out" >&2; exit 1; }; printf '%s\n' "$out"; }
recorded(){ ask "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '$db'"; }
exists(){ local n; n=$(ask "SELECT count(*) FROM pg_database WHERE datname = '$db'") || exit 1; [ "$n" = 1 ]; }
comment(){ psql -X "$LAPLACE_CONNINFO" -v ON_ERROR_STOP=1 -qc "COMMENT ON DATABASE \"$db\" IS '$1'"; }
out(){ echo "$1=$2"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >> "$GITHUB_OUTPUT"; }

case ${1:-show} in
  show)     stamp | while read -r r h c; do printf '%-20s tree %s  commit %s\n' "$r" "$h" "$c"; done; echo "stamp                $(want)" ;;
  recorded) recorded ;;
  pending)  comment "laplace-seed pending $(want) $(commits)sources=${LAPLACE_SOURCES:-all} from=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; recorded ;;
  seeded)   comment "laplace-seed done $(want) $(commits)sources=${LAPLACE_SOURCES:-all} at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; recorded ;;
  decide)
    w=$(want); have=""; exists && have=$(recorded) || true
    set -- $have; state=${2:-}; stamp_was=${3:-}
    if ! exists; then drop=false ingest=true why="no database $db: deploy.sh makes it, and it is seeded"
    elif [ "${1:-}" != laplace-seed ]; then drop=true ingest=true why="$db holds no seed stamp: it was not seeded by a deployment (or by a reseed from ingest.yml)"
    elif [ "$stamp_was" != "$w" ]; then drop=true ingest=true why="$db was seeded from $stamp_was ($(echo "$have" | grep -o 'native=[^ ]* engine=[^ ]* postgres=[^ ]* operations=[^ ]*')); the code now makes $w ($(commits))"
    elif [ "$state" = pending ]; then drop=false ingest=true why="$db's reseed to $w was cut off: the ingest is taken up again"
    else drop=false ingest=false why="$db is seeded from $w, what this code makes: nothing to reseed"; fi
    if [ "$LAPLACE_RESEED" = never ] && [ "$drop" = true ]; then drop=false ingest=false why="$why; LAPLACE_RESEED=never: not reseeded"; fi
    out drop "$drop"; out ingest "$ingest"; out stamp "$w"; out why "$why" ;;
  *) echo "seed-stamp.sh show|recorded|decide|pending|seeded"; exit 2 ;;
esac
