#!/usr/bin/env bash
# Build one Laplace CMake repository once per source revision and dependency set, and install it as its CMake package;
# print the prefix. A consumer configures with -D<Package>_DIR=<prefix>/lib/cmake/<Package> and compiles none of it.
#   package.sh NAME SOURCE [VARIABLE=VALUE...]       each a CMake cache setting (-DVARIABLE=VALUE)
#     package.sh laplace-native "$LAPLACE_SRC/Laplace-Native" LAPLACE_NATIVE_TESTS=OFF             (native-package.sh)
#     package.sh laplace-engine "$LAPLACE_SRC/Laplace-Engine" LaplaceNative_DIR=<native>/lib/cmake/LaplaceNative
# The prefix is $LAPLACE_BUILD/packages/NAME/<key>: the source's commit (a modified checkout: + its diff's digest) and,
# when settings are given, their digest; a dependency is named by its own keyed prefix, so a new Native is a new
# Engine package. Built with icx under this Operations' floating-point contract; a complete prefix is reused as is; the
# three most recent of a NAME are kept. Build output goes to stderr; stdout is the prefix alone.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=${1:?usage: package.sh NAME SOURCE [VARIABLE=VALUE...]}
source=$(cd "${2:?usage: package.sh NAME SOURCE [VARIABLE=VALUE...]}" && pwd)
shift 2
if [ -z "${LAPLACE_EIGEN_DIR:-}" ]; then
  if [ -f "${LAPLACE_DEPSRC:-${LAPLACE_SRC:-/repos/src}}/eigen/Eigen/Core" ]; then export LAPLACE_EIGEN_DIR="${LAPLACE_DEPSRC:-${LAPLACE_SRC:-/repos/src}}/eigen"
  elif [ -f /usr/include/eigen3/Eigen/Core ]; then export LAPLACE_EIGEN_DIR=/usr/include/eigen3; fi
fi
export LAPLACE_SPECTRA_DIR="${LAPLACE_SPECTRA_DIR:-${LAPLACE_DEPSRC:-${LAPLACE_SRC:-/repos/src}}/spectra}"
settings=(); for s in "$@"; do settings+=("-D$s"); done
key=$(git -c safe.directory="$source" -C "$source" rev-parse HEAD)
if [ -n "$(git -c safe.directory="$source" -C "$source" status --porcelain --untracked-files=no)" ]; then
  key=$key-$(git -c safe.directory="$source" -C "$source" diff HEAD | sha256sum | cut -c1-12)
fi
if [ $# -gt 0 ]; then key=$key-$(printf '%s\n' "$@" | sha256sum | cut -c1-12); fi
packages=$LAPLACE_BUILD/packages/$name
prefix=$packages/$key
rebuild_missing_linalg=0
if [ "$name" = laplace-native ] && [ -n "${LAPLACE_EIGEN_DIR:-}" ] && [ -f "$LAPLACE_SPECTRA_DIR/include/Spectra/SymEigsSolver.h" ] && [ ! -f "$prefix/lib/liblaplace_linalg.a" ]; then
  rebuild_missing_linalg=1
fi
if ! ls "$prefix"/lib/cmake/*/*Config.cmake >/dev/null 2>&1 || [ "$rebuild_missing_linalg" -eq 1 ]; then
  build=$LAPLACE_BUILD/$(basename "$source")/package
  cmake -S "$source" -B "$build" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLAPLACE_OPERATIONS="$here" -DCMAKE_INSTALL_PREFIX="$prefix" "${settings[@]}" >&2
  cmake --build "$build" >&2
  rm -rf "$prefix.partial" "$prefix.old"
  cmake --install "$build" --prefix "$prefix.partial" >&2
  if [ -e "$prefix" ]; then mv "$prefix" "$prefix.old"; fi
  mv "$prefix.partial" "$prefix"
  rm -rf "$prefix.old"
fi
ls -1dt "$packages"/*/ 2>/dev/null | tail -n +4 | while read -r old; do rm -rf -- "$old"; done
echo "$prefix"
