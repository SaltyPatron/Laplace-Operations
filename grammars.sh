#!/bin/bash
# The tree-sitter grammars Laplace decomposes code with, as grammars.tsv declares them (name, origin): cloned into
# $LAPLACE_GRAMMAR_SRC from each origin at their locked revisions commit of its default branch, at the machine's own network
# speed, so a new host has 300 grammars in minutes instead of receiving a copy of another machine's directory.
# build_grammars.sh (Laplace-Engine) compiles what is there.
#
#   ./grammars.sh fetch [DIR] [NAME...]    selected grammars (all if omitted); local modifications are refused
#   ./grammars.sh status [DIR]   each grammar: present at which commit, or missing; exit 1 when one is missing
#   ./grammars.sh record [DIR]   name, origin and HEAD of what DIR holds now: the record of a machine's grammars
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/laplace.env"
op=${1:-status}; dir=${2:-$LAPLACE_GRAMMAR_SRC}; manifest=$here/grammars.lock.tsv
selected=()
if (( $# > 2 )); then selected=("${@:3}"); fi
for name in "${selected[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] &&
    awk -F '\t' -v name="$name" 'NR > 1 && $1 == name { found++ } END { exit found != 1 }' "$manifest" ||
      { echo "No unique locked grammar: $name" >&2; exit 1; }
done
rows(){
  local name origin commit
  while IFS=$'\t' read -r name origin commit; do
    if (( ! ${#selected[@]} )) || [[ " ${selected[*]} " == *" $name "* ]]; then
      printf '%s\t%s\t%s\n' "$name" "$origin" "$commit"
    fi
  done < <(tail -n +2 "$manifest")
}
grammar_git(){
  local source
  source=$(cd "$1" && pwd -P) || return; shift
  git -c "safe.directory=$source" -c core.excludesFile= -C "$source" "$@"
}
case $op in
  fetch)
    # The grammar directory is shared by the operator and the CI runner through its setgid group: what either
    # creates stays group-writable, and a lock is taken on a read-only descriptor so a lock file the other
    # account created (whatever its mode) still serializes instead of refusing the run.
    umask 002; mkdir -p "$dir"; n=0; bad=0
    while IFS=$'\t' read -r name origin commit; do
      d=$dir/$name
      [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$commit" =~ ^[0-9a-f]{40}$ && "$origin" == https://* ]] || { echo 'Invalid locked grammar record' >&2; exit 1; }
      [ -e "$dir/.$name.lock" ] || : >>"$dir/.$name.lock"
      exec {grammar_lock}<"$dir/.$name.lock"; flock -xn "$grammar_lock" || { echo "$name is being updated" >&2; exit 1; }
      if [ ! -d "$d/.git" ]; then
        [[ ! -e "$d" || -z "$(ls -A "$d")" ]] || { echo "Nonempty source directory: $d" >&2; exit 1; }
        git init -q "$d"; grammar_git "$d" remote add origin "$origin"
      fi
      [[ "$(grammar_git "$d" remote get-url origin)" == "$origin" && -z "$(grammar_git "$d" status --porcelain)" ]] || { echo "Origin or local source changes at $d; not changed" >&2; exit 1; }
      if [[ "$(grammar_git "$d" rev-parse --verify HEAD 2>/dev/null || true)" != "$commit" ]]; then
        grammar_git "$d" fetch -q --depth 1 origin "$commit"
        grammar_git "$d" checkout -q --detach "$commit"
      fi
      exec {grammar_lock}>&-
      n=$((n + 1)); printf '  %-32s %s\n' "$name" "$(grammar_git "$d" rev-parse --short HEAD)"
    done < <(rows)
    echo "grammars: $n at their locked revisions, $bad not cloned, $(rows | wc -l) declared, under $dir"; [ "$bad" = 0 ] ;;
  status)
    bad=0
    while IFS=$'\t' read -r name origin commit; do
      d=$dir/$name; have=$(grammar_git "$d" rev-parse --short HEAD 2>/dev/null || true)
      if [ -n "$have" ]; then printf '  %-32s %s\n' "$name" "$have"; else printf '  %-32s missing\n' "$name"; bad=$((bad + 1)); fi
    done < <(rows)
    echo "grammars: $(rows | wc -l) declared, $bad missing, under $dir"; [ "$bad" = 0 ] ;;
  record)
    printf 'name\torigin\tcommit\n'
    for d in "$dir"/*/; do d=${d%/}; [ -d "$d/.git" ] || continue; printf '%s\t%s\t%s\n' "$(basename "$d")" "$(grammar_git "$d" remote get-url origin)" "$(grammar_git "$d" rev-parse HEAD)"; done ;;
  *) echo "grammars.sh fetch|status|record [DIR]"; exit 2 ;;
esac
