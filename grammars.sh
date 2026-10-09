#!/bin/bash
# The tree-sitter grammars Laplace decomposes code with, as grammars.tsv declares them (name, origin): cloned into
# $LAPLACE_GRAMMAR_SRC from each origin at the latest commit of its default branch, at the machine's own network
# speed, so a new host has 300 grammars in minutes instead of receiving a copy of another machine's directory.
# build_grammars.sh (Laplace-Engine) compiles what is there.
#
#   ./grammars.sh fetch [DIR]    every grammar of the manifest: cloned shallow when missing, pulled to the latest when there
#   ./grammars.sh status [DIR]   each grammar: present at which commit, or missing; exit 1 when one is missing
#   ./grammars.sh record [DIR]   name, origin and HEAD of what DIR holds now: the record of a machine's grammars
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/laplace.env"
op=${1:-status}; dir=${2:-$LAPLACE_GRAMMAR_SRC}; manifest=$here/grammars.tsv
rows(){ grep -v '^#' "$manifest" | grep .; }
case $op in
  fetch)
    mkdir -p "$dir"; n=0; bad=0
    while IFS=$'\t' read -r name origin; do
      d=$dir/$name
      if [ -d "$d/.git" ]; then git -C "$d" pull -q --ff-only 2>/dev/null || git -C "$d" fetch -q --depth 1 origin && git -C "$d" reset -q --hard FETCH_HEAD
      else git clone -q --depth 1 "$origin" "$d" || { bad=$((bad + 1)); printf '  %-32s COULD NOT CLONE %s\n' "$name" "$origin"; continue; }; fi
      n=$((n + 1)); printf '  %-32s %s\n' "$name" "$(git -C "$d" rev-parse --short HEAD)"
    done < <(rows)
    echo "grammars: $n at the latest, $bad not cloned, $(rows | wc -l) declared, under $dir"; [ "$bad" = 0 ] ;;
  status)
    bad=0
    while IFS=$'\t' read -r name origin; do
      d=$dir/$name; have=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || true)
      if [ -n "$have" ]; then printf '  %-32s %s\n' "$name" "$have"; else printf '  %-32s missing\n' "$name"; bad=$((bad + 1)); fi
    done < <(rows)
    echo "grammars: $(rows | wc -l) declared, $bad missing, under $dir"; [ "$bad" = 0 ] ;;
  record)
    printf 'name\torigin\tcommit\n'
    for d in "$dir"/*/; do d=${d%/}; [ -d "$d/.git" ] || continue; printf '%s\t%s\t%s\n' "$(basename "$d")" "$(git -C "$d" remote get-url origin)" "$(git -C "$d" rev-parse HEAD)"; done ;;
  *) echo "grammars.sh fetch|status|record [DIR]"; exit 2 ;;
esac
