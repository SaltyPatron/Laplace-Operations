#!/bin/bash
# The chess lab's conventional reference on Linux, from dependencies.tsv's rows for this platform: Stockfish built with
# profile-guided optimization, fastchess, Ordo, explicitly authorized CUDA Lc0, Lc0's networks and the
# opening suites. Run as the operator (sudo ./setup.sh chess runs it so); nothing here needs root.
#
#   chess/provision.sh            every chess row; each is made only when its proof is missing or wrong
#   chess/provision.sh stockfish  the named rows
#   chess/provision.sh report     what is installed, with each identity (Stockfish's bench, the SHA-256s)
#
# A program goes to $LAPLACE_DEPS/<name>/<version> (built in $LAPLACE_WORK/chess-build/<name>) and is linked as
# $LAPLACE_PREFIX/bin/<program>; a data row goes to $LAPLACE_DATA/<proof> with <proof>.sha256 beside it. Releases are
# verified by SHA-256 before they are used, sources are checked out at their pinned commit. Builds take
# $LAPLACE_CHESS_JOBS cores (default 2), so a running reseed keeps the machine. Stockfish's bench must print the
# generation's node count (deploy/stockfish-profiles.json in the monorepo: 2497913 for sf_19) or it is not installed.
#
# Lc0 and Syzygy: tablebases stay what the machine has (LAPLACE_SYZYGY); they are a provider an engine probes, not
# content Laplace depends on, and are not provisioned here.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); . "$here/laplace.env"
[ "$(id -u)" != 0 ] || { echo "run as the operator, not root (sudo ./setup.sh chess does this)"; exit 1; }
DEPS=$LAPLACE_DEPS; DATA=$LAPLACE_DATA; PREFIX=${LAPLACE_CHESS_PREFIX:-$LAPLACE_PREFIX}; WORK=$LAPLACE_WORK/chess-build
JOBS=${LAPLACE_CHESS_JOBS:-2}
SF_ARCH=${LAPLACE_STOCKFISH_ARCH:-x86-64-bmi2}           # hart-server's Broadwell-E: BMI2, AVX2, no VNNI, no AVX-512
SF_CXX=${LAPLACE_STOCKFISH_CXX:-g++-12}                  # newer than Ubuntu 22.04's default g++ 11.4
SF_BENCH=${LAPLACE_STOCKFISH_BENCH:-2497913}
NVCC=${LAPLACE_NVCC:-$(ls -d /usr/local/cuda/bin/nvcc 2>/dev/null || command -v nvcc || true)}
say(){ printf '  %-34s %s\n' "$1" "$2"; }
rows(){ awk -F'\t' '!/^#/ && NF >= 12 && $1 != "name" && $9 ~ /linux/' "$here/dependencies.tsv" | tr -d '\r'; }
want(){ local selected=$1; shift; [ $# -eq 0 ] && return 0; local item; for item in "$@"; do [ "$item" != "$selected" ] || return 0; done; return 1; }
sha(){ sha256sum "$1" | cut -c1-64; }
fetch(){ # url pin file: download once, verify
  local url=$1 pin=$2 file=$3
  mkdir -p "$(dirname "$file")"
  if [ ! -s "$file" ]; then curl -fsSL --retry 3 -o "$file.part" "$url" || { rm -f "$file.part"; echo "download failed: $url"; return 1; }; mv -f "$file.part" "$file"; fi
  [ "$(sha "$file")" = "$pin" ] || { echo "SHA-256 of $file is $(sha "$file"), the pin is $pin"; return 1; }
}
checkout(){ # origin commit dir
  [ -d "$3/.git" ] || git clone -q --filter=blob:none --no-checkout "$1" "$3"
  git -C "$3" rev-parse -q --verify "$2^{commit}" >/dev/null || git -C "$3" fetch -q origin "$2"
  git -C "$3" -c advice.detachedHead=false checkout -q "$2"
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ]
}
# a program's name on the PATH: linked now when the operator may write $PREFIX/bin, else left in links.pending for
# setup.sh chess to link as root
link(){ if [ -w "$PREFIX/bin" ]; then ln -sfn "$1" "$PREFIX/bin/$2"
        elif [ "$(readlink -f "$PREFIX/bin/$2" 2>/dev/null)" != "$(readlink -f "$1")" ]; then printf '%s\t%s\n' "$1" "$2" >> "$WORK/links.pending"; fi; }

stockfish(){ local name=$1 version=$2 origin=$3 pin=$6 proof=${12}; local prefix=$DEPS/$name/$version src=$WORK/$name
  if [ -x "$prefix/$proof" ] && [ "$("$prefix/$proof" bench 2>&1 | awk '/Nodes searched/{print $4}')" = "$SF_BENCH" ]; then
    say "$name $version" "at $prefix ($("$prefix/$proof" compiler | awk -F': ' '/architecture/{print $2}'), bench $SF_BENCH)"; link "$prefix/$proof" stockfish; return; fi
  command -v "$SF_CXX" >/dev/null || { say "$name" "NOT BUILT: no $SF_CXX"; return 1; }
  checkout "$origin" "$pin" "$src"
  # the network is downloaded by the Makefile and checked against its name's hash prefix
  nice make -C "$src/src" -j"$JOBS" profile-build ARCH="$SF_ARCH" COMP=gcc CXX="$SF_CXX" >"$WORK/$name.log" 2>&1 || { say "$name" "BUILD FAILED: $WORK/$name.log"; return 1; }
  local bench; bench=$("$src/src/stockfish" bench 2>&1 | awk '/Nodes searched/{print $4}')
  [ "$bench" = "$SF_BENCH" ] || { say "$name" "REFUSED: bench $bench, the generation's is $SF_BENCH"; return 1; }
  install -d "$prefix/bin"; install -m 0755 "$src/src/stockfish" "$prefix/$proof"
  "$prefix/$proof" compiler > "$prefix/compiler.txt"; sha "$prefix/$proof" > "$prefix/$proof.sha256"
  link "$prefix/$proof" stockfish
  say "$name $version" "built ($SF_ARCH, $SF_CXX, profile-build), bench $bench, at $prefix"
}
release(){ local name=$1 version=$2 origin=$4 pin=$6 build=$7 proof=${12}; local prefix=$DEPS/$name/$version
  local file=$WORK/download/$name-$version/$(basename "$origin")
  if [ -e "$prefix/.pin" ] && [ "$(cat "$prefix/.pin")" = "$pin" ] && [ -x "$prefix/$proof" ]; then say "$name $version" "at $prefix"; link "$prefix/$proof" "$name"; return; fi
  fetch "$origin" "$pin" "$file"
  rm -rf "$prefix.part"; mkdir -p "$prefix.part"
  case $file in *.tar) tar -xf "$file" -C "$prefix.part" ;; *.tar.gz|*.tgz) tar -xzf "$file" -C "$prefix.part" ;; *) echo "no unpacking for $file"; return 1 ;; esac
  local top; top=$(find "$prefix.part" -mindepth 1 -maxdepth 1); [ "$(echo "$top" | wc -l)" = 1 ] && [ -d "$top" ] || top=$prefix.part
  if [ "$build" = make ]; then   # the release's source: make where its Makefile is (Ordo's is under sources/)
    local mk; mk=$(find "$top" -maxdepth 2 -name Makefile | sort | head -1); [ -n "$mk" ] || { say "$name" "no Makefile in $(basename "$file")"; return 1; }
    nice make -C "$(dirname "$mk")" -j"$JOBS" >"$WORK/$name.log" 2>&1 || { say "$name" "BUILD FAILED: $WORK/$name.log"; return 1; }; fi
  rm -rf "$prefix"; mkdir -p "$(dirname "$prefix")"; mv "$top" "$prefix"; rm -rf "$prefix.part"; echo "$pin" > "$prefix/.pin"
  [ -x "$prefix/$proof" ] || { say "$name" "NO $proof in $prefix"; return 1; }
  link "$prefix/$proof" "$name"; say "$name $version" "at $prefix"
}
lc0(){ local name=$1 version=$2 origin=$3 pin=$6 proof=${12}; local prefix=$DEPS/$name/$version src=$WORK/$name
  # Hardware presence is not permission to probe or use it. A copied declaration
  # cannot authorize a different host; an empty declaration leaves CUDA disabled.
  local gpu_host=${LAPLACE_GPU_HOST:-} actual_host; actual_host=$(hostname -s)
  if [[ -z "$gpu_host" || "${gpu_host,,}" != "${actual_host,,}" ]]; then
    say "$name" "skipped: GPU not authorized for $actual_host (LAPLACE_GPU_HOST)"; return
  fi
  command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 || { say "$name" "skipped: no NVIDIA GPU"; return; }
  if [ -x "$prefix/$proof" ] && [ "$(cat "$prefix/.pin" 2>/dev/null)" = "$pin" ]; then say "$name $version" "at $prefix"; link "$prefix/$proof" lc0; return; fi
  [ -x "$NVCC" ] || { say "$name" "NOT BUILT: no nvcc (LAPLACE_NVCC)"; return 1; }
  checkout "$origin" "$pin" "$src"
  # plain CUDA backend only (no cuDNN on this machine): Backend=cuda; nvcc's host compiler must be one it accepts
  local cuda; cuda=$(dirname "$(dirname "$(readlink -f "$NVCC")")")
  ( cd "$src" && rm -rf build && PATH=$cuda/bin:$PATH CC=gcc-11 CXX=g++-11 nice meson setup build --buildtype=release \
      -Dplain_cuda=true -Dcudnn=false -Dblas=false -Donnx=false -Dgtest=false -Dnative_cuda=false \
      -Dcc_cuda="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)" -Dnvcc_ccbin=g++-11 \
      -Dcudnn_libdirs="$cuda/lib64" -Dcudnn_include="$cuda/include" >"$WORK/$name.log" 2>&1 && \
    PATH=$cuda/bin:$PATH nice ninja -C build -j"$JOBS" >>"$WORK/$name.log" 2>&1 ) || { say "$name" "BUILD FAILED: $WORK/$name.log"; return 1; }
  install -d "$prefix/bin"; install -m 0755 "$src/build/lc0" "$prefix/$proof"; echo "$pin" > "$prefix/.pin"
  sha "$prefix/$proof" > "$prefix/$proof.sha256"; link "$prefix/$proof" lc0
  say "$name $version" "built (CUDA $(basename "$cuda"), plain cuda backend), at $prefix"
}
data(){ local name=$1 origin=$4 pin=$6 build=$7 proof=${12}; local target=$DATA/$proof
  if [ -e "$target" ] && [ -e "$target.sha256" ] && [ "$(cat "$target.sha256")" = "$(sha "$target")" ]; then say "$name" "at $target"; return; fi
  local file=$WORK/download/$name/$(basename "$origin"); fetch "$origin" "$pin" "$file"; mkdir -p "$(dirname "$target")"
  if [ "$build" = zip ]; then
    [ "$(unzip -Z1 "$file" | grep -vc '/$')" = 1 ] || { echo "$file holds more than one file"; return 1; }
    unzip -p "$file" > "$target.part" && mv -f "$target.part" "$target"
  else cp -f "$file" "$target"; fi
  sha "$target" > "$target.sha256"; say "$name" "at $target"
}
report(){
  for p in stockfish fastchess ordo lc0; do
    if command -v "$PREFIX/bin/$p" >/dev/null 2>&1; then say "$p" "$(readlink -f "$PREFIX/bin/$p")  sha256 $(sha "$(readlink -f "$PREFIX/bin/$p")" | cut -c1-16)"; else say "$p" "not installed"; fi
  done
  [ -x "$PREFIX/bin/stockfish" ] && say "stockfish bench" "$("$PREFIX/bin/stockfish" bench 2>&1 | awk '/Nodes searched|Nodes\/second/{printf "%s ", $NF}')"
  rows | awk -F'\t' '$3 == "data" {print $12}' | while read -r proof; do
    [ -e "$DATA/$proof" ] && say "$(basename "$proof")" "$(sha "$DATA/$proof" | cut -c1-16)" || say "$(basename "$proof")" "missing"; done
}

mkdir -p "$WORK"
[ "${1:-}" = report ] && { report; exit 0; }
rm -f "$WORK/links.pending"
failed=0
while IFS=$'\t' read -r name version kind origin ref pin build profile platforms depends use proof; do
  want "$name" "$@" || continue
  case $kind/$build in
    source/stockfish) stockfish "$name" "$version" "$origin" "$ref" "$kind" "$pin" "$build" "$profile" "$platforms" "$depends" "$use" "$proof" || failed=1 ;;
    source/lc0)       lc0 "$name" "$version" "$origin" "$ref" "$kind" "$pin" "$build" "$profile" "$platforms" "$depends" "$use" "$proof" || failed=1 ;;
    release/unpack|release/make)
                      case $name in fastchess|ordo) release "$name" "$version" "$kind" "$origin" "$ref" "$pin" "$build" "$profile" "$platforms" "$depends" "$use" "$proof" || failed=1 ;; esac ;;
    data/file|data/zip) data "$name" "$version" "$kind" "$origin" "$ref" "$pin" "$build" "$profile" "$platforms" "$depends" "$use" "$proof" || failed=1 ;;
  esac
done < <(rows)
[ ! -s "$WORK/links.pending" ] || { echo "  to link as root (sudo ./setup.sh chess):"; sed 's/^/    /' "$WORK/links.pending"; }
exit $failed
