#!/usr/bin/env bash
# Laplace-Native as the CMake package LaplaceNative (package.sh laplace-native); print the prefix.
#   native-package.sh [native-source]          default $LAPLACE_NATIVE, else $LAPLACE_SRC/Laplace-Native
set -euo pipefail
exec bash "$(dirname "$0")/package.sh" laplace-native "${1:-${LAPLACE_NATIVE:-$LAPLACE_SRC/Laplace-Native}}" LAPLACE_NATIVE_TESTS=OFF
