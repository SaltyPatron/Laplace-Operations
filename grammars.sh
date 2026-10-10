#!/bin/bash
# The tree-sitter grammars Laplace decomposes code with, as grammars.tsv declares them (name, origin): cloned into
# $LAPLACE_GRAMMAR_SRC from each origin at their locked revisions commit of its default branch, at the machine's own network
# speed, so a new host has 300 grammars in minutes instead of receiving a copy of another machine's directory.
# build_grammars.sh (Laplace-Engine) compiles what is there.
#
#   ./grammars.sh fetch [DIR]    every grammar of the manifest: fetched at the locked commit; local modifications are refused
#   ./grammars.sh status [DIR]   each grammar: present at which commit, or missing; exit 1 when one is missing
#   ./grammars.sh record [DIR]   name, origin and HEAD of what DIR holds now: the record of a machine's grammars
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/laplace.env"
op=${1:-status}; dir=${2:-$LAPLACE_GRAMMAR_SRC}; manifest=$here/grammars.lock.tsv
rows(){ tail -n +2 "$manifest"; }
case $op in
  fetch)
    mkdir -p "$dir"; n=0; bad=0
    while IFS=$'\t' read -r name origin commit; do
      d=$dir/$name
      [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$commit" =~ ^[0-9a-f]{40}$ && "$origin" == https://* ]] || { echo 'Invalid locked grammar record' >&2; exit 1; }
      mkdir -p "$dir"
      exec {grammar_lock}>"$dir/.$name.lock"; flock -xn "$grammar_lock" || { echo "$name is being updated" >&2; exit 1; }
      if [ ! -d "$d/.git" ]; then
        [[ ! -e "$d" || -z "$(ls -A "$d")" ]] || { echo "Nonempty source directory: $d" >&2; exit 1; }
        git init -q "$d"; git -C "$d" remote add origin "$origin"
      fi
      [[ "$(git -C "$d" remote get-url origin)" == "$origin" && -z "$(git -C "$d" status --porcelain)" ]] || { echo "Origin or local source changes at $d; not changed" >&2; exit 1; }
      if [[ "$(git -C "$d" rev-parse --verify HEAD 2>/dev/null || true)" != "$commit" ]]; then
        git -C "$d" fetch -q --depth 1 origin "$commit"
        git -C "$d" checkout -q --detach "$commit"
      fi
      exec {grammar_lock}>&-
      n=$((n + 1)); printf '  %-32s %s\n' "$name" "$(git -C "$d" rev-parse --short HEAD)"
    done < <(rows)
    echo "grammars: $n at their locked revisions, $bad not cloned, $(rows | wc -l) declared, under $dir"; [ "$bad" = 0 ] ;;
  status)
    bad=0
    while IFS=$'\t' read -r name origin commit; do
      d=$dir/$name; have=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || true)
      if [ -n "$have" ]; then printf '  %-32s %s\n' "$name" "$have"; else printf '  %-32s missing\n' "$name"; bad=$((bad + 1)); fi
    done < <(rows)
    echo "grammars: $(rows | wc -l) declared, $bad missing, under $dir"; [ "$bad" = 0 ] ;;
  record)
    printf 'name\torigin\tcommit\n'
    for d in "$dir"/*/; do d=${d%/}; [ -d "$d/.git" ] || continue; printf '%s\t%s\t%s\n' "$(basename "$d")" "$(git -C "$d" remote get-url origin)" "$(git -C "$d" rev-parse HEAD)"; done ;;
  *) echo "grammars.sh fetch|status|record [DIR]"; exit 2 ;;
esac
