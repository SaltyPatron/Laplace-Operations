#!/bin/sh
# Build Laplace: Laplace-Native once, installed as the CMake package LaplaceNative (native-package.sh), then the
# extension and the engine against that package.
#   ./build.sh            build both
#   ./build.sh install    also install the extension into PostgreSQL's directories
set -e
stage=
trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
. "$(dirname "$0")/laplace.env"
if [ "${1:-}" = install ]; then
  . "$(dirname "$0")/operation-lock.sh"
  laplace_host_lock exclusive
fi
bash "$LAPLACE_SRC/Laplace-Engine/tools/build_grammars.sh" "$LAPLACE_SRC/Laplace-Engine/recipes/formats/grammars" "$LAPLACE_GRAMMARS"
native=$(bash "$(dirname "$0")/native-package.sh" "$LAPLACE_SRC/Laplace-Native")
for r in Laplace-postgres Laplace-Engine; do
  cmake -S "$LAPLACE_SRC/$r" -B "$LAPLACE_BUILD/$r/icx-release" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLaplaceNative_DIR="$native/lib/cmake/LaplaceNative" -DLAPLACE_NATIVE="$LAPLACE_SRC/Laplace-Native" -DLAPLACE_OPERATIONS="$LAPLACE_SRC/Laplace-Operations" -DLAPLACE_TIER0="$LAPLACE_TIER0" -DLAPLACE_RECIPES="$LAPLACE_SRC/Laplace-Engine/recipes"
  cmake --build "$LAPLACE_BUILD/$r/icx-release"
done
# Installed by rename, never by overwriting in place: a backend that has the old library mapped keeps the old inode.
[ "${1:-}" = install ] && { stage=$(mktemp -d); DESTDIR=$stage cmake --install "$LAPLACE_BUILD/Laplace-postgres/icx-release" >/dev/null
  (cd "$stage" && find . -type f) | while read -r f; do mv -f "$stage/$f" "/${f#./}"; done; rm -rf "$stage"; }
"$LAPLACE_BUILD/Laplace-Engine/icx-release/laplace" 2>&1 | tail -5
