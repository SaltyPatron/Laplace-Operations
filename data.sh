#!/bin/bash
# The data sets the recipes read, as data.tsv declares them (set, kind, origin, into): fetched into $LAPLACE_DATA from
# each publisher at the latest, at the machine's own network speed, so a new host has the Unicode data, ISO 639 and
# the wordnet in minutes instead of receiving a copy of another machine's directory. Nothing here is renamed or
# rewritten: a file lands as the publisher serves it, at the path the recipe reads it from.
#
#   ./data.sh fetch [SET...]    every declared set (or these): mirrored, downloaded when newer, the latest release, an archive opened
#   ./data.sh status            each declared set present or missing, then each recipe's roots: resolved or not;
#                               exit 1 when a declared set is missing
#   ./data.sh record            set, file, bytes, SHA-256 of what $LAPLACE_DATA holds for the declared sets
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/laplace.env"
op=${1:-status}; shift || true; manifest=$here/data.tsv; recipes=$LAPLACE_SRC/Laplace-Engine/recipes
rows(){ grep -v '^#' "$manifest" | grep .; }
sets(){ rows | cut -f1 | sed 's/-{edition}$/-*/' | sort -u; }                   # a release set's directory carries its edition
get(){ curl -fsSL --retry 3 -R --create-dirs -o "$2" ${3:+-z "$3"} "$1"; }     # -R: the publisher's time; -z: only when newer
urls(){ sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p"; }                          # the download URLs of a GitHub listing or release
land(){ local set=$1 into=$2 name=$3; case $into in */) echo "$LAPLACE_DATA/$set/${into#./}$name" ;; .) echo "$LAPLACE_DATA/$set" ;; *) echo "$LAPLACE_DATA/$set/$into" ;; esac; }
fetch_row(){ local set=$1 kind=$2 origin=$3 into=$4 dest
  case $kind in
    mirror) dest=$LAPLACE_DATA/$set; mkdir -p "$dest"
            wget -q -r -np -nH -N -R 'index.html*' -P "$dest" "$origin" || [ $? = 8 ]   # 8: a file the server would not give; the rest came
            printf '  %-28s %s files from %s\n' "$set" "$(find "$dest" -type f | wc -l)" "$origin" ;;
    file)   dest=$(land "$set" "$into" "${origin##*/}"); get "$origin" "$dest" "$([ -f "$dest" ] && echo "$dest")"
            printf '  %-28s %s\n' "$set" "${dest#"$LAPLACE_DATA"/}" ;;
    listing) local u; for u in $(curl -fsSL "$origin" | urls download_url); do
              dest=$(land "$set" "$into" "${u##*/}"); get "$u" "$dest" "$([ -f "$dest" ] && echo "$dest")"; done
            printf '  %-28s %s: %s files from %s\n' "$set" "${into%/}" "$(ls "$LAPLACE_DATA/$set/${into%/}" | wc -l)" "$origin" ;;
    release) local u name edition pre=${into%%\**}
            u=$(curl -fsSL "$origin" | urls browser_download_url | while read -r x; do case ${x##*/} in $into) echo "$x"; break ;; esac; done)
            [ -n "$u" ] || { echo "  $set: no asset of the latest release matches $into"; return 1; }
            name=${u##*/}; edition=${name#"$pre"}; edition=${edition%%.*}; set=${set//\{edition\}/$edition}   # the name after the pattern's prefix, before its extension
            dest=$LAPLACE_DATA/$set/$name; get "$u" "$dest" "$([ -f "$dest" ] && echo "$dest")"
            printf '  %-28s %s, the latest release\n' "$set" "$name" ;;
    extract) dest=$LAPLACE_DATA/$set/${into%/}; mkdir -p "$dest"
            unzip -q -o -DD "$LAPLACE_DATA/$set/$origin" -d "$dest"          # the publisher's archive, opened beside itself
            printf '  %-28s %s opened into %s\n' "$set" "${origin##*/}" "${into%/}" ;;
    *) echo "  $set: $kind is not a kind data.sh fetches"; return 1 ;;
  esac; }
case $op in
  fetch)
    mkdir -p "$LAPLACE_DATA"; bad=0; want=" $* "
    while IFS=$'\t' read -r set kind origin into; do
      [ -z "$*" ] || case $want in *" ${set%-\{edition\}} "*|*" $set "*) ;; *) continue ;; esac
      fetch_row "$set" "$kind" "$origin" "$into" || { bad=$((bad + 1)); printf '  %-28s NOT FETCHED %s\n' "$set" "$origin"; }
    done < <(rows)
    echo "data: $(rows | wc -l) declared, $bad not fetched, under $LAPLACE_DATA"; [ "$bad" = 0 ] ;;
  status)
    bad=0
    for s in $(sets); do
      d=$(ls -d "$LAPLACE_DATA"/$s 2>/dev/null | tail -1 || true)
      if [ -n "$d" ] && [ -n "$(ls -A "$d")" ]; then printf '  %-28s %s files\n' "${d##*/}" "$(find "$d" -type f | wc -l)"; else printf '  %-28s missing\n' "$s"; bad=$((bad + 1)); fi
    done
    echo "data: $(sets | wc -l) sets declared, $bad missing, under $LAPLACE_DATA"
    if [ -d "$recipes" ]; then echo "recipes' roots:"
      for src in "$recipes"/*/source; do
        name=$(sed -n 's/^name //p' "$src" | head -1); n=0
        while read -r root; do r=$(eval echo "$root"); for d in $r; do [ -d "$d" ] && { printf '  %-28s %s\n' "$name" "${d#"$LAPLACE_DATA"/}"; n=1; }; done; done < <(sed -n 's/^root //p' "$src")
        [ "$n" = 1 ] || printf '  %-28s no root present\n' "$name"
      done
    fi; [ "$bad" = 0 ] ;;
  record)
    printf 'set\tfile\tbytes\tsha256\n'
    for s in $(sets); do for d in "$LAPLACE_DATA"/$s; do [ -d "$d" ] || continue
      find "$d" -type f -printf '%s\t%p\n' | sort -k2 | while IFS=$'\t' read -r bytes f; do printf '%s\t%s\t%s\t%s\n' "${d##*/}" "${f#"$d"/}" "$bytes" "$(sha256sum "$f" | cut -c1-64)"; done; done; done ;;
  *) echo "data.sh fetch [SET...]|status|record"; exit 2 ;;
esac
