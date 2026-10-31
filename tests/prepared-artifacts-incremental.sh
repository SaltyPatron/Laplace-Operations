#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?use build scratch storage}/prepared-artifacts.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/input" "$work/installed caches"
# Exercise the production installer without deployment, a database, or secrets.
sed -n '/^install_prepared_inputs() (/ ,/^)/p' "$ROOT/deploy.sh" > "$work/install.sh"
test -s "$work/install.sh"
grep -Fq '  install_prepared_inputs "$LAPLACE_PREPARED_INPUTS"' "$ROOT/deploy.sh"
install_prepared_inputs() {
  /bin/sh -c '. "$1"; install_prepared_inputs "$2"' prepared-installer "$work/install.sh" "$1"
}
export LAPLACE_TIER0="$work/installed caches/tier0.bin"
export LAPLACE_HIGHWAY="$work/installed caches/tier0.highway"
unset LAPLACE_FLAGS
artifacts=(tier0.bin tier0.flags tier0.flags.layout tier0.highway)
for name in "${artifacts[@]}"; do printf '%s version 1\n' "$name" > "$work/input/$name"; done
install_prepared_inputs "$work/input"
for name in "${artifacts[@]}"; do
  cmp "$work/input/$name" "$work/installed caches/$name"
  test "$(stat -c %a "$work/installed caches/$name")" = 664
done
cat > "$work/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.22)
project(PreparedInputs NONE)
foreach(name tier0.bin tier0.flags tier0.flags.layout tier0.highway)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/installed caches/${name}" "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/installed caches/${name}" VERBATIM)
  list(APPEND prepared "${CMAKE_CURRENT_BINARY_DIR}/${name}")
endforeach()
add_custom_target(consumer ALL DEPENDS ${prepared})
CMAKE
cmake -S "$work" -B "$work/build" -G Ninja > "$work/configure.log"
cmake --build "$work/build" > "$work/first-build.log"
snapshot() {
  for name in "${artifacts[@]}"; do stat -c '%n %i %y %a' "$work/installed caches/$name"; done
}
snapshot > "$work/before"
install_prepared_inputs "$work/input"
snapshot > "$work/after"
diff -u "$work/before" "$work/after"
cmake --build "$work/build" > "$work/repeated-build.log"
grep -Fq 'ninja: no work to do.' "$work/repeated-build.log"
echo 'PASS identical prepared artifacts retain inode, timestamp, mode and no-work consumer build'

printf 'changed highway\n' > "$work/input/tier0.highway"
install_prepared_inputs "$work/input"
cmake --build "$work/build" > "$work/changed-build.log"
cmp "$work/input/tier0.highway" "$work/build/tier0.highway"
echo 'PASS changed prepared artifact rebuilds its actual consumer'

touch -r "$work/installed caches/tier0.bin" "$work/old-time"
printf 'corrupted artifact\n' > "$work/installed caches/tier0.bin"
touch -r "$work/old-time" "$work/installed caches/tier0.bin"
install_prepared_inputs "$work/input"
cmake --build "$work/build" > "$work/repaired-build.log"
cmp "$work/input/tier0.bin" "$work/build/tier0.bin"
echo 'PASS corrupted bytes with the original timestamp are repaired and consumed'

chmod 600 "$work/installed caches/tier0.flags"
install_prepared_inputs "$work/input"
test "$(stat -c %a "$work/installed caches/tier0.flags")" = 664
printf 'unrelated target\n' > "$work/unrelated"
cp "$work/unrelated" "$work/unrelated-before"
rm "$work/installed caches/tier0.flags.layout"
ln -s "$work/unrelated" "$work/installed caches/tier0.flags.layout"
install_prepared_inputs "$work/input"
test ! -L "$work/installed caches/tier0.flags.layout"
cmp "$work/unrelated-before" "$work/unrelated"
cmp "$work/input/tier0.flags.layout" "$work/installed caches/tier0.flags.layout"
echo 'PASS declared file mode converges and replacing a leaf symlink preserves its former target'

snapshot > "$work/before-custom-path"
export LAPLACE_FLAGS="$work/custom selection/resource flags"
install_prepared_inputs "$work/input"
cmp "$work/input/tier0.flags" "$LAPLACE_FLAGS"
cmp "$work/input/tier0.flags.layout" "$LAPLACE_FLAGS.layout"
snapshot > "$work/after-custom-path"
diff -u "$work/before-custom-path" "$work/after-custom-path"
unset LAPLACE_FLAGS
echo 'PASS an explicit flags path is honored without rewriting the default destinations'

# A failed copy cannot replace the previous file or leave a partial temporary.
mv "$work/input/tier0.bin" "$work/held-input"
snapshot > "$work/before-failure"
if install_prepared_inputs "$work/input" > "$work/failed-copy.log" 2>&1; then
  echo 'FAIL missing input was accepted' >&2; exit 1
fi
snapshot > "$work/after-failure"
diff -u "$work/before-failure" "$work/after-failure"
test "$(find "$work/installed caches" -type f | wc -l)" = 4
echo 'PASS failed artifact copy preserves the installed files and removes its temporary'
