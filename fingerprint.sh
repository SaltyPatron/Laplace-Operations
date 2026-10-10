#!/bin/sh
# What this machine's build of Laplace makes, as one record that another machine's record for the same commits can be
# laid beside, line for line: the "does it work on another machine" question (Architecture: bit-perfect determinism
# across hardware and operating systems). fingerprint.ps1 is the Windows counterpart and writes the same record.
#
#   ./fingerprint.sh record FILE    the record of the build under $LAPLACE_BUILD for the code under $LAPLACE_SRC
#   ./fingerprint.sh publish FILE   put it on the branch `fingerprints` of Laplace-Operations, at <native>-<engine>/<machine>.txt
#   ./fingerprint.sh compare FILE   lay it beside every other machine's record for the same commits (exit 1 on a difference)
#   ./fingerprint.sh compare FILE DIR   the same, against the records (*.txt) in DIR in place of the branch's
#   ./fingerprint.sh inputs         what this machine's results are made from: the lines of the record that say its data
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

# What the results are made from, so that two records which differ can be told apart by their inputs before their
# arithmetic: the Unicode data tier 0, its flags and the unicode source are read from (its version, as DerivedAge.txt
# names it, and its files but the charts), the ICU text is decomposed with and the Unicode version that ICU is of, and
# the directory each source is read from whose results are in the record: the sources of $LAPLACE_DETERMINISM, and the
# resources the highway was generated from (as its log names them). A source's directory is its first root that
# exists; of a pattern, the newest: as the engine resolves it. A tree is said as its files and one hash: of
# "path<TAB>bytes<TAB>sha256" for every file, in byte order of the paths. A name that begins with a dot, file or directory,
# is not in it: the engine's walk does not read one (data.sh keeps .landed and .archive there).
tree(){ ( cd "$1" && shift && find . -type f -not -path '*/.*' "$@" | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' "${f#./}" "$(wc -c < "$f" | tr -d ' ')" "$(sha256sum < "$f" | cut -c1-64)"; done ); }
said(){ t=$(mktemp); cat > "$t"; echo "$(wc -l < "$t" | tr -d ' ') $(sha256sum < "$t" | cut -c1-16)"; rm -f "$t"; }
inputs(){
  u=$LAPLACE_UCD/Public/UCD/latest                                         # where tier0.c, flags.c and the unicode recipe read it
  if [ -d "$u" ]; then v=$(sed -n '1s/^# DerivedAge-\([0-9.]*\)\.txt.*/\1/p' "$u/ucd/DerivedAge.txt" 2>/dev/null)
    echo "ucd         ${v:-unknown} $(tree "$u" -not -path './charts/*' | said)"
  else echo "ucd         none"; fi
  i=$LAPLACE_ICU_DIR/include/unicode
  echo "icu         $(sed -n 's/^#define U_ICU_VERSION "\(.*\)".*/\1/p' "$i/uvernum.h" 2>/dev/null | head -1) unicode $(sed -n 's/^#define U_UNICODE_VERSION "\(.*\)".*/\1/p' "$i/uchar.h" 2>/dev/null | head -1)"
  res=$(resources | tr '\n' ' '); echo "resources   ${res% }"
  seen=" "
  for s in $LAPLACE_DETERMINISM $res; do case $seen in *" $s "*) continue ;; esac; seen="$seen$s "; d=
    for root in $(sed -n 's/^root  *//p' "$LAPLACE_SRC/Laplace-Engine/recipes/$s/source" 2>/dev/null); do
      [ -n "$d" ] && break; for c in $(eval echo "$root"); do [ -d "$c" ] && d=$c; done; done
    if [ -n "$d" ]; then echo "data        $s $(tree "$d" | said) ${d##*/}"; else echo "data        $s none"; fi
  done; }
# the resources the last deployment's highway was read from: each line of its log between the title and the slots
resources(){ h=$(ls -d "$LAPLACE_WORK"/logs/deploy/*/ 2>/dev/null | sort | tail -1); [ -n "$h" ] && [ -f "$h/highway.log" ] || return 0
  sed -n '/^laplace highway/,/^  slots:/p' "$h/highway.log" | sed -n 's/^  \([a-z][a-z0-9-]*\)  *[0-9n].*/\1/p'; }

record(){ out=$1; [ -x "$L" ] || { echo "no laplace at $L: deploy.sh builds it"; exit 1; }
  scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
  { echo "machine     $(hostname)"
    echo "os          $(uname -sr)"
    echo "cpu         $(sed -n 's/^model name[^:]*: //p' /proc/cpuinfo 2>/dev/null | head -1)"
    echo "compiler    $(icx --version 2>/dev/null | head -1)"
    echo "made        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for r in Laplace-Native Laplace-Engine Laplace-postgres Laplace-Operations; do
      printf '%-11s %s%s\n' "$(echo "$r" | sed 's/Laplace-//' | tr 'A-Z' 'a-z')" "$(commit "$r")" "$(dirty "$r")"; done
    inputs
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

# Laying two records side by side. fld: one field of a record; dat: a source's data as "files hash" (or none);
# same: two values as same, differs, or unknown (one is not said: a record from before the inputs were); both: two such
# answers as one (any differs: differs; else any unknown: unknown); why: what a result's difference then is.
fld(){ sed -n "s/^$2  *//p" "$1" | head -1; }
dat(){ sed -n "s/^data  *$2  *\([0-9][0-9]* [0-9a-f][0-9a-f]*\).*/\1/p; s/^data  *$2  *none.*/none/p" "$1" | head -1; }
same(){ if [ -z "$1" ] || [ -z "$2" ]; then echo unknown; elif [ "$1" = "$2" ]; then echo same; else echo differs; fi; }
both(){ if [ "$1" = differs ] || [ "$2" = differs ]; then echo differs; elif [ "$1" = unknown ] || [ "$2" = unknown ]; then echo unknown; else echo same; fi; }
why(){ case $1 in differs) echo "(its inputs differ: not a difference of arithmetic)" ;; same) echo "(from the same inputs: the machines compute differently)" ;; *) echo "(the inputs are not said in both records)" ;; esac; }

compare(){ f=$1; given=${2:-}; k=$(key "$f"); m=$(sed -n 's/^machine  *//p' "$f"); d=$(mktemp -d); rc=0
  url=https://github.com/$LAPLACE_GITHUB/Laplace-Operations.git; tok=${LAPLACE_FINGERPRINT_TOKEN:-}
  if [ -n "$given" ]; then mkdir -p "$d/$k"; cp "$given"/*.txt "$d/$k"/ 2>/dev/null || true   # compare FILE DIR: the records in DIR, in place of the branch's
  elif [ -n "$tok" ]; then git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')" clone -q --depth 1 --branch fingerprints "$url" "$d" 2>/dev/null || true
  else git clone -q --depth 1 --branch fingerprints "$url" "$d" 2>/dev/null || true; fi
  n=0
  for o in "$d/$k"/*.txt; do [ -f "$o" ] || continue; om=$(basename "$o" .txt); [ "$om" = "$m" ] && continue; n=$((n + 1))
    echo "against $om ($(sed -n 's/^os  *//p' "$o"); made $(sed -n 's/^made  *//p' "$o"))"
    # the inputs first: what differs in a result is then said to follow from them, or to be the machines' arithmetic
    ucd=$(same "$(fld "$f" ucd)" "$(fld "$o" ucd)")
    for field in ucd icu; do a=$(fld "$f" $field); b=$(fld "$o" $field)
      case $(same "$a" "$b") in same) echo "  $field: same ($a)" ;; differs) echo "  $field: DIFFERS: $a here, $b there"; rc=1 ;; *) echo "  $field: not in both" ;; esac; done
    for s in $(sed -n 's/^data  *\([^ ]*\).*/\1/p' "$f"); do a=$(dat "$f" "$s"); b=$(dat "$o" "$s")
      case $(same "$a" "$b") in same) echo "  data $s: same ($a)" ;; differs) echo "  data $s: DIFFERS: $a here, $b there"; rc=1 ;; *) echo "  data $s: not in both" ;; esac; done
    hw=$ucd; for s in $(fld "$f" resources); do hw=$(both "$hw" "$(same "$(dat "$f" "$s")" "$(dat "$o" "$s")")"); done
    for field in tier0 flags highway; do a=$(fld "$f" $field); b=$(fld "$o" $field); [ $field = highway ] && in=$hw || in=$ucd
      case $(same "$a" "$b") in same) echo "  $field: same ($a)" ;; differs) echo "  $field: DIFFERS: $a here, $b there   $(why "$in")"; rc=1 ;; *) echo "  $field: not in both" ;; esac; done
    for s in $(sed -n 's/^claims  *\([^ ]*\).*/\1/p' "$f"); do a=$(fld "$f" "claims  *$s"); b=$(fld "$o" "claims  *$s")
      in=$(both "$ucd" "$(same "$(dat "$f" "$s")" "$(dat "$o" "$s")")")
      case $(same "$a" "$b") in same) echo "  claims $s: same ($a)" ;; differs) echo "  claims $s: DIFFERS: $a here, $b there   $(why "$in")"; rc=1 ;; *) echo "  claims $s: not decomposed there" ;; esac; done
  done
  [ "$n" -gt 0 ] || echo "no other machine has a record for $k yet (on HART-DESKTOP: fingerprint.ps1 at these commits)"
  rm -rf "$d"; return $rc; }

case ${1:-} in
  record)  record "${2:?file}" ;;
  inputs)  inputs ;;
  publish) publish "${2:?file}" ;;
  compare) compare "${2:?file}" "${3:-}" ;;
  *) echo "fingerprint.sh record|publish|compare FILE, or inputs"; exit 2 ;;
esac
