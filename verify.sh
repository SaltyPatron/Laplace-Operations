#!/bin/sh
# Deployment readback and separately invoked build qualification, each written to the
# workflow's summary ($GITHUB_STEP_SUMMARY; to the terminal otherwise) and kept under $LAPLACE_WORK/logs/verify.
#
#   ./verify.sh deployment  extension version/tables and Engine/PostgreSQL artifact compatibility; no generation or ingest
#   ./verify.sh build    no database: the record of this build (fingerprint.sh: commits, tier 0 and its flags made
#                        afresh, the highway, the claims of $LAPLACE_DETERMINISM decomposed twice), the tier 0 installed
#                        against the one this build makes, and the record laid beside every other machine's for the same
#                        commits (HART-DESKTOP's, from fingerprint.ps1); published on the branch fingerprints
#   ./verify.sh reads    the database: laplace status, and reads through the indexes (text, hop, translate)
#   ./verify.sh tests    the database checks of the deployed revisions, against the deployed database through the deployed
#                        programs and the installed extension: Laplace-postgres tests/deployed.sh (its regression cases,
#                        each in a transaction it rolls back), Laplace-Engine tests/deployed/run.sh and Laplace-MCP
#                        tests/deployed/run.sh (each check ingests its own sources, asserts on what is under its own
#                        witnesses, and forgets them). Nothing is made, dropped or emptied
#
# Exit 1 when something that must hold does not: two decompositions of one source differ, the installed tier 0 is not
# this build's, a result differs from another machine's that had the same inputs (or its ICU or Unicode version does), the
# status says DIFFERS, or a read fails. Data a host holds that another does not is said, and fails nothing.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
case ${1:-build} in
  deployment|reads|tests) . "$here/operation-lock.sh"; laplace_host_lock shared ;;
esac
L=${LAPLACE_PROGRAM:-$LAPLACE_BUILD/Laplace-Engine/icx-release/laplace}
log=$LAPLACE_WORK/logs/verify/$(date -u +%Y%m%dT%H%M%SZ)-${1:-build}; mkdir -p "$log"
summary=${GITHUB_STEP_SUMMARY:-}
md(){ if [ -n "$summary" ]; then printf '%s\n' "$*" >> "$summary"; else printf '%s\n' "$*"; fi; }
block(){ md '```'; if [ -n "$summary" ]; then cat "$1" >> "$summary"; else cat "$1"; fi; md '```'; }
rc=0; bad(){ rc=1; md "- **FAIL** $*"; [ -z "$summary" ] || printf 'FAIL %s\n' "$*"; }; good(){ md "- ok: $*"; }

deployment(){
  md "## $(hostname): deployment readback"
  if ! "$L" text a > "$log/engine-tier0.txt" 2>&1; then bad 'the selected Engine cannot read tier 0'; return; fi
  if ! "$L" highway --fingerprint > "$log/engine-highway.txt" 2>&1; then bad 'the selected Engine cannot read the installed highway'; return; fi
  t0=$(sed -n 's/^tier 0  *\([0-9a-f]\{64\}\).*/\1/p' "$log/engine-tier0.txt")
  hw=$(sed -n 's/^fingerprint  *\([0-9a-f]\{64\}\).*/\1/p' "$log/engine-highway.txt")
  if [ "${#t0}" != 64 ] || [ "${#hw}" != 64 ]; then bad 'Engine did not return both artifact fingerprints'; return; fi
  if ! "$LAPLACE_PG_DIR/bin/psql" "$LAPLACE_CONNINFO" -XAt -v ON_ERROR_STOP=1 -F '|' -c "
    SELECT e.extversion, a.default_version, laplace_fingerprint(), laplace_highway_fingerprint(),
      to_regclass('entity') IS NOT NULL AND to_regclass('physicality') IS NOT NULL
      AND to_regclass('attestation') IS NOT NULL AND to_regclass('consensus') IS NOT NULL
    FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname WHERE e.extname='laplace'" > "$log/database.txt" 2> "$log/database.err"; then
    bad 'database extension readback failed'; block "$log/database.err"; return
  fi
  # The extension's version is the content hash of its install script (Laplace-postgres): the server's installed
  # candidate is its default_version, and a database made from any other script holds another version.
  IFS='|' read -r version expected database_t0 database_hw schema < "$log/database.txt" || { bad 'database extension is absent'; return; }
  [ -n "$expected" ] && [ "$version" = "$expected" ] && good "extension version $version" || bad "extension version $version; the installed extension is ${expected:-missing}"
  [ "$schema" = t ] && good 'required extension tables exist' || bad 'required extension tables are missing'
  [ "$database_t0" = "$t0" ] && good 'Engine and PostgreSQL use the same tier-0 artifact' || bad 'Engine/PostgreSQL tier-0 fingerprints differ or are missing'
  [ "$database_hw" = "$hw" ] && good 'Engine and PostgreSQL use the same highway artifact' || bad 'Engine/PostgreSQL highway fingerprints differ or are missing'
  # Record SHA256 hashes of the observed runtime artifacts.
  sha256sum "$L" "$LAPLACE_TIER0" "$LAPLACE_HIGHWAY" "${LAPLACE_FLAGS:-${LAPLACE_TIER0%.bin}.flags}" "${LAPLACE_FLAGS:-${LAPLACE_TIER0%.bin}.flags}.layout" > "$log/runtime.sha256" || { bad 'could not record runtime artifact bytes'; return; }
  block "$log/runtime.sha256"
}

build(){
  md "## $(hostname): the build"
  "$here/seed-stamp.sh" show > "$log/stamp.txt" 2>&1 || true; block "$log/stamp.txt"
  "$here/fingerprint.sh" record "$log/record.txt" > /dev/null 2> "$log/record.err" || { bad "no record: $(tail -1 "$log/record.err")"; return; }
  md "### The record"; block "$log/record.txt"
  grep '^determinism' "$log/record.txt" | while read -r _ s verdict rest; do
    if [ "$verdict" = same: ]; then echo "ok $s: $rest"; else echo "FAIL $s: decomposed twice, two claim sets: $rest"; fi; done > "$log/determinism.txt"
  md "### Determinism: the same source decomposed twice"
  while read -r v line; do if [ "$v" = ok ]; then good "$line"; else bad "$line (SaltyPatron/Laplace-Engine#36)"; fi; done < "$log/determinism.txt"
  grep -q '^claims .* failed' "$log/record.txt" && bad "a source's claims could not be decomposed: $(grep '^claims .* failed' "$log/record.txt" | head -1)"
  # What the results are made from. Tier 0 is generated from the Unicode data and text is decomposed by ICU: the two
  # must be of one Unicode version, or what this machine names is not what a machine with matching ones names.
  md "### What it is made from"
  uv=$(sed -n 's/^ucd  *\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$log/record.txt"); iv=$(sed -n 's/^icu  .* unicode  *\([0-9][0-9.]*\).*/\1/p' "$log/record.txt")
  if [ -z "$uv" ] || [ -z "$iv" ]; then bad "the record does not say its Unicode data ($(sed -n 's/^ucd  *//p' "$log/record.txt")) or its ICU ($(sed -n 's/^icu  *//p' "$log/record.txt"))"
  elif [ "$uv" = "$iv" ]; then good "the Unicode data under $LAPLACE_UCD is $(sed -n 's/^ucd  *\([^ ]*\).*/\1/p' "$log/record.txt"), the version ICU $(sed -n 's/^icu  *\([^ ]*\).*/\1/p' "$log/record.txt") is of"
  else bad "the Unicode data under $LAPLACE_UCD is $(sed -n 's/^ucd  *\([^ ]*\).*/\1/p' "$log/record.txt"); ICU $(sed -n 's/^icu  *\([^ ]*\).*/\1/p' "$log/record.txt") is of Unicode $iv: tier 0 and the decomposition of text are of two versions (data.tsv says which the Unicode data is fetched at)"; fi
  sed -n 's/^data  *\([^ ]*\)  *none.*/\1/p' "$log/record.txt" | while read -r s; do md "- $s is at none of its roots on this machine: what it says is in no result here"; done
  md "### Tier 0 installed"
  made=$(sed -n 's/^tier0  *//p' "$log/record.txt"); installed=$("$L" text a 2>/dev/null | sed -n 's/^tier 0  *\([0-9a-f]\{64\}\).*/\1/p')
  if [ -z "$made" ]; then bad "tier 0 was not made afresh (see $log)"
  elif [ "$made" = "$installed" ]; then good "$LAPLACE_TIER0 is the tier 0 this build makes ($made)"
  else bad "$LAPLACE_TIER0 is $installed; this build makes $made: prepare or install the required artifact separately; dropping the database does not regenerate it"; fi
  md "### Against other machines, same commits"
  comparison=0
  "$here/fingerprint.sh" compare "$log/record.txt" > "$log/compare.txt" 2>&1 || comparison=$?
  case $comparison in
    0) good "record comparison completed; see the field results below" ;;
    2) bad "cross-machine comparison incomplete: required evidence is unavailable" ;;
    *) bad "cross-machine comparison failed; see the field results below" ;;
  esac
  block "$log/compare.txt"
  if "$here/fingerprint.sh" publish "$log/record.txt" > "$log/publish.txt" 2>&1; then md "- $(tail -1 "$log/publish.txt") on the branch fingerprints of Laplace-Operations"
  else md "- the record was not published: $(tail -1 "$log/publish.txt")"; fi
}

read_one(){ name=$1 limit=$2; shift 2; s=$(date +%s%N)
  if timeout "$limit" "$L" "$@" > "$log/$name.txt" 2>&1; then r=0; else r=$?; fi
  ms=$(( ($(date +%s%N) - s) / 1000000 )); echo "$r $ms"; }
reads(){
  md "## $(hostname): the database ($(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p'))"
  if "$L" status > "$log/status.txt" 2>&1; then
    if grep -q DIFFERS "$log/status.txt"; then bad "laplace status: the database's tier 0 or highway DIFFERS from this engine's"; else good "laplace status"; fi
  else bad "laplace status failed"; fi
  block "$log/status.txt"
  # Whether any witness has attested anything, asked of the table itself (status counts planner estimates, which say
  # "not counted yet" right after a load): only a database that holds attestations is required to answer the hop.
  if ! held=$("$LAPLACE_PG_DIR/bin/psql" "$LAPLACE_CONNINFO" -XAt -v ON_ERROR_STOP=1 -c 'SELECT EXISTS (SELECT 1 FROM attestation)' 2> "$log/held.err"); then
    bad 'could not ask the database whether it holds attestations'; block "$log/held.err"; return
  fi
  case $held in t|f) ;; *) bad "the database answered '$held' to whether it holds attestations"; return ;; esac
  md "### Reads"; md "| read | exit | ms | first lines |"; md "|---|---|---|---|"
  for r in "text|30|text hello" "hop|120|hop -n 5 dog" "translate|120|translate dog en fr"; do
    name=${r%%|*}; rest=${r#*|}; limit=${rest%%|*}; args=${rest#*|}
    # shellcheck disable=SC2086
    set -- $(read_one "$name" "$limit" $args); e=$1 ms=$2
    first=$(grep -v '^\s*$' "$log/$name.txt" | head -3 | cut -c1-90 | tr '|' '/' | sed 's/$/<br>/' | tr -d '\n')
    md "| laplace $args | $e | $ms | $first |"
    [ "$e" = 0 ] || { bad "laplace $args exited $e"; continue; }
    case $name in
      text) grep -Eq '^entity +[0-9a-f]{32} +tier [0-9]+' "$log/$name.txt" || bad "laplace $args named no entity" ;;
      hop) claims=$(sed -n 's/^attested: \([0-9][0-9]*\) claim.*/\1/p' "$log/$name.txt")
        if [ -z "$claims" ]; then bad "laplace $args printed no attested count"
        elif [ "$held" = t ] && [ "$claims" = 0 ]; then bad "laplace $args: the database holds attestations, and none about dog was read"
        else good "laplace $args: $claims claims attested"; fi ;;
      translate) grep -q ' steps, each one set ' "$log/$name.txt" || bad "laplace $args did not finish its steps" ;;
    esac
  done
  [ "$held" = t ] || md "- **EMPTY**: the database holds no attestations: the reads ran and prove nothing until a source is in"
}

tests(){
  db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p')
  md "## $(hostname): the database checks of the deployed revisions ($db)"
  scratch=$(mktemp -d "$LAPLACE_WORK/tmp-checks.XXXXXX") || { bad 'no scratch directory under LAPLACE_WORK'; return; }
  # The deployed MCP service's release, where this host declares one (installation/<host>-modular.json).
  # A host with no declaration at all runs no MCP; a host that declares one must declare it for the database under test.
  declared=$(python3 "$here/installation/modular.py" select 2> "$log/select.err") || { bad 'modular declaration selection failed'; block "$log/select.err"; rm -rf "$scratch"; return; }
  lpm=
  if [ -n "$declared" ]; then
    manifest=$(python3 "$here/installation/modular.py" select --database "$db" 2> "$log/select.err") || { bad 'modular declaration selection failed'; block "$log/select.err"; rm -rf "$scratch"; return; }
    if [ -z "$manifest" ]; then bad "this host declares a modular runtime ($declared) for another database than $db: its MCP checks cannot run"
    else lpm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prefix"])' "$manifest")/current/bin/lpm || { bad "the prefix of $manifest cannot be read"; lpm=; }
      [ -z "$lpm" ] || [ -x "$lpm" ] || bad "this host declares a modular runtime ($manifest) and no release is installed at $lpm"; fi
  fi
  for component in "Laplace-postgres|tests/deployed.sh" "Laplace-Engine|tests/deployed/run.sh" "Laplace-MCP|tests/deployed/run.sh"; do
    repo=${component%%|*}; runner=$LAPLACE_SRC/$repo/${component#*|}
    if [ "$repo" = Laplace-MCP ] && [ -z "$declared" ]; then md "- $repo: SKIPPED: this host declares no modular runtime (no LAPLACE_MODULAR_MANIFEST and no installation/$(hostname | tr '[:upper:]' '[:lower:]')-modular.json), so no MCP is checked"; continue; fi
    if [ "$repo" = Laplace-MCP ] && [ ! -x "$lpm" ]; then continue; fi    # its failure is said above
    [ -f "$runner" ] || { bad "$repo has no $runner"; continue; }
    if TMPDIR=$scratch LAPLACE_PROGRAM=$L LAPLACE_ENGINE_BUILD=$LAPLACE_BUILD/Laplace-Engine/icx-release \
       LAPLACE_ENGINE_SOURCE=$LAPLACE_SRC/Laplace-Engine LAPLACE_LPM=$lpm \
       bash "$runner" > "$log/$repo.log" 2>&1; then good "$repo: $(tail -1 "$log/$repo.log")"
    else bad "$repo: $(tail -1 "$log/$repo.log")"; fi
    grep -E '^(engine|mcp|postgres) check ' "$log/$repo.log" > "$log/$repo.checks" || true
    if [ -s "$log/$repo.checks" ]; then block "$log/$repo.checks"; else md '```'; tail -40 "$log/$repo.log" >> "${summary:-/dev/stdout}"; md '```'; fi
  done
  rm -rf "$scratch"
}

case ${1:-build} in
  deployment) deployment ;;
  build) build ;;
  reads) reads ;;
  tests) tests ;;
  *) echo "verify.sh deployment|build|reads|tests"; exit 2 ;;
esac
echo "verify.sh ${1:-build}: $( [ $rc = 0 ] && echo passed || echo FAILED ); kept in $log"
exit $rc
