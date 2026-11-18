#!/usr/bin/env bash
# Build Laplace-Native once per source revision and install it as the CMake package LaplaceNative; print the prefix.
# Every consumer (Laplace-postgres, Laplace-Engine, Laplace-MCP) then configures with -DCMAKE_PREFIX_PATH=<prefix>
# and compiles none of Native itself.
#   native-package.sh [native-source]          default $LAPLACE_NATIVE, else $LAPLACE_SRC/Laplace-Native
# The prefix is $LAPLACE_BUILD/packages/laplace-native/<commit> (a modified checkout: <commit>-<diff digest>), built
# under this Operations' floating-point contract; an existing complete prefix is reused as is. The three most recent
# prefixes are kept.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
native=$(cd "${1:-${LAPLACE_NATIVE:-$LAPLACE_SRC/Laplace-Native}}" && pwd)
key=$(git -C "$native" rev-parse HEAD)
if [ -n "$(git -C "$native" status --porcelain --untracked-files=no)" ]; then
  key=$key-$(git -C "$native" diff HEAD | sha256sum | cut -c1-12)
fi
packages=$LAPLACE_BUILD/packages/laplace-native
prefix=$packages/$key
if [ ! -f "$prefix/lib/cmake/LaplaceNative/LaplaceNativeConfig.cmake" ]; then
  build=$LAPLACE_BUILD/Laplace-Native/package
  cmake -S "$native" -B "$build" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLAPLACE_NATIVE_TESTS=OFF -DLAPLACE_OPERATIONS="$here" \
    -DCMAKE_INSTALL_PREFIX="$prefix" >&2
  cmake --build "$build" >&2
  rm -rf "$prefix.partial"
  cmake --install "$build" --prefix "$prefix.partial" >&2
  mv "$prefix.partial" "$prefix"
fi
ls -1dt "$packages"/*/ 2>/dev/null | tail -n +4 | while read -r old; do rm -rf -- "$old"; done
echo "$prefix"
