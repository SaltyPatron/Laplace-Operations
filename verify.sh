#!/bin/sh
# Does it work on another machine: the checks a deployment target runs after a deployment, each written to the
# workflow's summary ($GITHUB_STEP_SUMMARY; to the terminal otherwise) and kept under $LAPLACE_WORK/logs/verify.
#
#   ./verify.sh build    no database: the record of this build (fingerprint.sh: commits, tier 0 and its flags made
#                        afresh, the highway, the claims of $LAPLACE_DETERMINISM decomposed twice), the tier 0 installed
#                        against the one this build makes, and the record laid beside every other machine's for the same
#                        commits (HART-DESKTOP's, from fingerprint.ps1); published on the branch fingerprints
#   ./verify.sh reads    the database: laplace status, and reads through the indexes (text, hop, translate, fills)
#
# Exit 1 when something that must hold does not: two decompositions of one source differ, the installed tier 0 is not
# this build's, a result differs from another machine's that had the same inputs (or its ICU or Unicode version does), the
# status says DIFFERS, or a read fails. Data a host holds that another does not is said, and fails nothing.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
L=${LAPLACE_PROGRAM:-$LAPLACE_BUILD/Laplace-Engine/icx-release/laplace}
log=$LAPLACE_WORK/logs/verify/$(date -u +%Y%m%dT%H%M%SZ)-${1:-build}; mkdir -p "$log"
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
md(){ printf '%s\n' "$*" >> "$summary"; }
block(){ md '```'; cat "$1" >> "$summary"; md '```'; }
rc=0; bad(){ rc=1; md "- **FAIL** $*"; }; good(){ md "- ok: $*"; }

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
  else bad "$LAPLACE_TIER0 is $installed; this build makes $made: deploy.sh drop makes it again (with a reseed)"; fi
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
  empty=0; grep -q 'consensus  *[1-9]' "$log/status.txt" || empty=1        # a standing for every claim a witness's records say (provenance is containment: no attestation table)
  md "### Reads"; md "| read | exit | ms | first lines |"; md "|---|---|---|---|"
  for r in "text|30|text hello" "hop|120|hop -n 5 dog" "translate|120|translate dog en fr" "fills|60|fills -n 5 the"; do
    name=${r%%|*}; rest=${r#*|}; limit=${rest%%|*}; args=${rest#*|}
    # shellcheck disable=SC2086
    set -- $(read_one "$name" "$limit" $args); e=$1 ms=$2
    first=$(grep -v '^\s*$' "$log/$name.txt" | head -3 | cut -c1-90 | tr '|' '/' | sed 's/$/<br>/' | tr -d '\n')
    md "| laplace $args | $e | $ms | $first |"
    case $name in fills) ;;                                      # fills is measured, not required (it can take minutes)
      *) [ "$e" = 0 ] || bad "laplace $args exited $e" ;; esac
  done
  [ "$empty" = 0 ] || md "- the database holds no standings yet: reads say nothing until a source is in"
}

case ${1:-build} in
  build) build ;;
  reads) reads ;;
  *) echo "verify.sh build|reads"; exit 2 ;;
esac
echo "verify.sh ${1:-build}: $( [ $rc = 0 ] && echo passed || echo FAILED ); kept in $log"
exit $rc
