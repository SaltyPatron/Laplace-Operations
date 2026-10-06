#!/bin/sh
# What this machine's build of Laplace makes, as one record that another machine's record for the same commits can be
# laid beside, line for line: the "does it work on another machine" question (Architecture: bit-perfect determinism
# across hardware and operating systems). fingerprint.ps1 is the Windows counterpart and writes the same record.
#
#   ./fingerprint.sh record FILE    the record of the build under $LAPLACE_BUILD for the code under $LAPLACE_SRC
#   ./fingerprint.sh publish FILE   put it on the branch `fingerprints` of Laplace-Operations, at <native>-<engine>/<machine>.txt
#   ./fingerprint.sh compare FILE   lay it beside every other machine's record for the same commits (exit 1 on a difference)
#
# The record: the commits, the compiler and the processor (said, never compared), then what must be the same on every
# machine: tier 0 and its flags, made afresh into a scratch directory from $LAPLACE_UCD; the highway the last
# deployment generated; and, for each source of $LAPLACE_DETERMINISM, the claims its recipes make of its files (laplace
# ingest --claims, nothing loaded), counted and hashed as a sorted set. Each source is decomposed twice: the two runs
# must give the same set (SaltyPatron/Laplace-Engine#36), and the record says whether they did.
# Publishing needs a token that may push to Laplace-Operations (LAPLACE_FINGERPRINT_TOKEN; in a workflow the secret
# LAPLACE_CHECKOUT), or the operator's own git credentials.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/laplace.env"
L=${LAPLACE_PROGRAM:-$LAPLACE_BUILD/Laplace-Engine/icx-release/laplace}
commit(){ git -c safe.directory='*' -C "$LAPLACE_SRC/$1" rev-parse --short=12 HEAD 2>/dev/null || echo none; }
dirty(){ [ -z "$(git -c safe.directory='*' -C "$LAPLACE_SRC/$1" status --porcelain --untracked-files=no 2>/dev/null)" ] || echo "+dirty"; }
fp(){ sed -n 's/^fingerprint.* \([0-9a-f]\{64\}\).*/\1/p' | head -1; }
key(){ echo "$(sed -n 's/^native  *\([^ +]*\).*/\1/p' "$1")-$(sed -n 's/^engine  *\([^ +]*\).*/\1/p' "$1")"; }

record(){ out=$1; [ -x "$L" ] || { echo "no laplace at $L: deploy.sh builds it"; exit 1; }
  scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
  { echo "machine     $(hostname)"
    echo "os          $(uname -sr)"
    echo "cpu         $(sed -n 's/^model name[^:]*: //p' /proc/cpuinfo 2>/dev/null | head -1)"
    echo "compiler    $(icx --version 2>/dev/null | head -1)"
    echo "made        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for r in Laplace-Native Laplace-Engine Laplace-postgres Laplace-Operations; do
      printf '%-11s %s%s\n' "$(echo "$r" | sed 's/Laplace-//' | tr 'A-Z' 'a-z')" "$(commit "$r")" "$(dirty "$r")"; done
    echo "tier0       $("$L" tier0 -o "$scratch/tier0.bin" 2>&1 | fp)"
    echo "flags       $(LAPLACE_TIER0=$scratch/tier0.bin "$L" flags -o "$scratch/tier0.flags" 2>&1 | fp)"
    h=$(ls -d "$LAPLACE_WORK"/logs/deploy/*/ 2>/dev/null | sort | tail -1)
    echo "highway     $( [ -n "$h" ] && fp < "$h/highway.log" )"
    for s in $LAPLACE_DETERMINISM; do
      for i in 1 2; do
        LAPLACE_WORK=$scratch/work LAPLACE_INGEST_ONE=1 "$L" ingest --claims "$s" > "$scratch/claims.$i" 2> "$scratch/claims.$i.err" || { echo "claims      $s failed: $(tail -1 "$scratch/claims.$i.err")"; continue 2; }
        grep '^\[' "$scratch/claims.$i" | LC_ALL=C sort > "$scratch/sorted.$i"
        eval "n$i=\$(wc -l < \"\$scratch/sorted.$i\" | tr -d ' ')"; eval "h$i=\$(sha256sum < \"\$scratch/sorted.$i\" | cut -c1-16)"
        eval "c$i=\$(sed -n 's/^ *\([0-9,]*\) compositions.*/\1/p' \"\$scratch/claims.$i\" | tail -1)"
      done
      echo "claims      $s $n1 $h1"
      if [ "$n1 $h1" = "$n2 $h2" ]; then echo "determinism $s same: twice $n1 claims, $h1"
      else echo "determinism $s DIFFERS: $n1 claims $h1, then $n2 claims $h2 (compositions $c1, then $c2)"; fi
    done
  } > "$out"
  cat "$out"; }

publish(){ f=$1; k=$(key "$f"); m=$(sed -n 's/^machine  *//p' "$f"); d=$(mktemp -d)
  url=https://github.com/$LAPLACE_GITHUB/Laplace-Operations.git
  tok=${LAPLACE_FINGERPRINT_TOKEN:-}
  g(){ if [ -n "$tok" ]; then git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')" "$@"; else git "$@"; fi; }
  if ! g clone -q --depth 20 --branch fingerprints "$url" "$d" 2>/dev/null; then
    g clone -q --depth 1 "$url" "$d"; git -C "$d" checkout -q --orphan fingerprints; git -C "$d" rm -rqf .
    printf '# Fingerprints\n\nOne directory per pair of commits (Laplace-Native-Laplace-Engine), one record per machine: fingerprint.sh and fingerprint.ps1 write them, and compare a record with every other one beside it.\n' > "$d/README.md"; fi
  mkdir -p "$d/$k"; cp "$f" "$d/$k/$m.txt"
  git -C "$d" add -A; git -C "$d" -c user.name="${GIT_AUTHOR_NAME:-laplace-$m}" -c user.email="${GIT_AUTHOR_EMAIL:-laplace@$m}" commit -qm "$k: $m" || { echo "unchanged"; rm -rf "$d"; return 0; }
  for t in 1 2 3 4 5; do g -C "$d" push -q origin fingerprints && { echo "published $k/$m.txt"; rm -rf "$d"; return 0; }
    g -C "$d" pull -q --rebase origin fingerprints || true; done
  echo "not published"; rm -rf "$d"; return 1; }

compare(){ f=$1; k=$(key "$f"); m=$(sed -n 's/^machine  *//p' "$f"); d=$(mktemp -d); rc=0
  url=https://github.com/$LAPLACE_GITHUB/Laplace-Operations.git; tok=${LAPLACE_FINGERPRINT_TOKEN:-}
  if [ -n "$tok" ]; then git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')" clone -q --depth 1 --branch fingerprints "$url" "$d" 2>/dev/null || true
  else git clone -q --depth 1 --branch fingerprints "$url" "$d" 2>/dev/null || true; fi
  n=0
  for o in "$d/$k"/*.txt; do [ -f "$o" ] || continue; om=$(basename "$o" .txt); [ "$om" = "$m" ] && continue; n=$((n + 1))
    echo "against $om ($(sed -n 's/^os  *//p' "$o"); made $(sed -n 's/^made  *//p' "$o"))"
    for field in tier0 flags highway; do a=$(sed -n "s/^$field  *//p" "$f"); b=$(sed -n "s/^$field  *//p" "$o")
      if [ -z "$a" ] || [ -z "$b" ]; then echo "  $field: not in both"; elif [ "$a" = "$b" ]; then echo "  $field: same ($a)"; else echo "  $field: DIFFERS: $a here, $b there"; rc=1; fi; done
    sed -n 's/^claims  *//p' "$f" | while read -r s cnt h; do b=$(sed -n "s/^claims  *$s  *//p" "$o")
      if [ -z "$b" ]; then echo "  claims $s: not decomposed there"; elif [ "$cnt $h" = "$b" ]; then echo "  claims $s: same ($cnt, $h)"; else echo "  claims $s: DIFFERS: $cnt $h here, $b there"; fi; done
    sed -n 's/^claims  *//p' "$f" | while read -r s cnt h; do b=$(sed -n "s/^claims  *$s  *//p" "$o"); [ -z "$b" ] || [ "$cnt $h" = "$b" ] || exit 1; done || rc=1
  done
  [ "$n" -gt 0 ] || echo "no other machine has a record for $k yet (on HART-DESKTOP: fingerprint.ps1 at these commits)"
  rm -rf "$d"; return $rc; }

case ${1:-} in
  record)  record "${2:?file}" ;;
  publish) publish "${2:?file}" ;;
  compare) compare "${2:?file}" ;;
  *) echo "fingerprint.sh record|publish|compare FILE"; exit 2 ;;
esac
