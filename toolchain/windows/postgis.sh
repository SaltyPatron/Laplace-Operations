#!/bin/sh
# PostGIS on Windows: configure, build and install it into the PostgreSQL built from dependencies.tsv, with icx-cc
# (icx's GNU-style driver, MSVC ABI) under the floating-point contract. Runs in MSYS2's shell (MSYSTEM=MSYS,
# MSYS2_PATH_TYPE=inherit) started from the oneAPI dev shell (load-env.ps1), with MSYS2's autotools, make and
# mingw-w64-ucrt-x86_64-gcc (whose cpp preprocesses PostGIS's SQL).
#
#   toolchain/windows/postgis.sh [configure] [build] [install]      (no argument: all three)
#
# Reads LAPLACE_DEPS (installs), LAPLACE_DEPSRC (sources), LAPLACE_BUILD (build trees) and LAPLACE_MATH (laplace-math
# static library). PostGIS's sources are checked out at their pin; the patches in patches/postgis are applied here.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ops=$(cd "$here/../.." && pwd)
tsv=$ops/toolchain/determinism.tsv
unix() { cygpath -u "$1"; }
D=$(unix "${LAPLACE_DEPS:?}")
SRC=$(unix "${LAPLACE_DEPSRC:?}")/postgis
B=$(unix "${LAPLACE_BUILD:?}")/deps/postgis
MATH=$(unix "${LAPLACE_MATH:?laplace-math static library}")
ver() { awk -F'\t' -v n="$1" '$1==n {print $2}' "$ops/dependencies.tsv" | tr -d '\r'; }
PG=$D/postgresql/$(ver postgresql)
GEOS=$D/geos/$(ver geos)
PROJ=$D/proj/$(ver proj)
XML=$D/libxml2/$(ver libxml2)
JSONC=$D/json-c/$(ver json-c)
ICONV=$D/win-iconv/$(ver win-iconv)
ZLIB=$D/zlib/$(ver zlib)
S=$B-shims
# laplace-math's 128-bit conversions come from the compiler's runtime; by its short name: libtool splits on spaces.
RT=$(cygpath -m -s "$(icx /clang:-print-resource-dir | tr -d '\r')/lib/windows/clang_rt.builtins-x86_64.lib")

# The contract's compile flags for the GNU driver, with its -no-intel-lib: a link option on Linux, but on Windows the
# default libraries are named in each object, so there it keeps libmmd and svml out of PostGIS's own objects.
FP=$(awk -F'\t' '{sub(/\r$/, "")} $1=="compile" && $2=="gnu" {printf "%s ", $3}
  $1=="nobuiltin" {n=split($3,a," "); for(i=1;i<=n;i++) printf "-fno-builtin-%s ", a[i]}' "$tsv")
# icx-cc's link step names the static CRT whatever -fms-runtime-lib says, and every icx object names libmmd (Intel's
# libm) as a default library, which link.exe may search before a library named later: both are dropped, and the link
# ends with laplace-math, then libmmd (determinism.tsv).
LINK_CRT="-fms-runtime-lib=dll -Wl,/NODEFAULTLIB:libcmt,/NODEFAULTLIB:libmmt,/NODEFAULTLIB:svml_dispmt,/NODEFAULTLIB:libmmd"
LIBDIRS="-L$S -L$ZLIB/lib -L$ICONV/lib -L$JSONC/lib -L$PROJ/lib -L$XML/lib -L$GEOS/lib"
export PATH="$PG/bin:$GEOS/bin:$XML/bin:$PROJ/bin:$PATH"

shims() {
  mkdir -p "$S"
  # Library names the MinGW-oriented build asks for: -lm (nothing on Windows: the CRT and laplace-math), -lpgcommon
  # and -lpgport (frontend libraries; a backend module takes them from postgres.lib), -lpq and -lxml2.
  printf 'typedef int laplace_empty_unit;\n' > "$S/empty.c"
  icx-cc -c "$S/empty.c" -o "$S/empty.obj"
  for l in m pgcommon pgport; do llvm-lib /out:"$(cygpath -m "$S/$l.lib")" "$(cygpath -m "$S/empty.obj")"; done
  cp "$PG/lib/libpq.lib" "$S/pq.lib"
  cp "$XML/lib/libxml2.lib" "$S/xml2.lib"
  cp "$here/icx-pgxs" "$S/icx-pgxs"
  # pg_config: PostgreSQL was built with icx-cl, whose MSVC-style --cc and --cflags autotools cannot use.
  cat > "$S/pg_config" <<EOF
#!/bin/sh
case "\$1" in
  --cc) echo icx-cc ;;
  --cflags) echo "$FP -O2" ;;
  *) "$PG/bin/pg_config.exe" "\$@" | tr -d '\r' ;;
esac
EOF
  # geos-config: GEOS's CMake build installs none.
  cat > "$S/geos-config" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo $(ver geos) ;;
  --prefix) echo "$GEOS" ;;
  --cflags|--includes) echo "-I$GEOS/include" ;;
  --clibs) echo "-L$GEOS/lib -lgeos_c" ;;
  --libs|--ldflags) echo "-L$GEOS/lib -lgeos" ;;
  *) exit 1 ;;
esac
EOF
  # cpp for the SQL scripts: MinGW's, whose cc1 loads its own DLLs (zlib, zstd, iconv) from PATH and fails without a
  # word when PostgreSQL's bin directory supplies same-named ones first.
  cat > "$S/sqlcpp" <<'EOF'
#!/bin/sh
PATH=/ucrt64/bin:$PATH exec /ucrt64/bin/cpp "$@"
EOF
  chmod +x "$S/icx-pgxs" "$S/pg_config" "$S/geos-config" "$S/sqlcpp"
}

patches() {
  cd "$SRC"
  for p in "$ops"/patches/postgis/*.patch; do
    if git apply --reverse --check "$p" 2>/dev/null; then continue; fi
    git apply "$p"
  done
}

configure() {
  shims
  patches
  # a checkout of the pinned commit carries configure.ac, not configure: its own autogen.sh makes it, once
  [ -x "$SRC/configure" ] || ( cd "$SRC" && ./autogen.sh )
  mkdir -p "$B" && cd "$B"
  # _cv_*: the probes for math errno and signed zeros run programs the contract makes behave as PostGIS wants.
  _cv_nomatherrno=no _cv_nosignedzeros=no \
  CC=icx-cc CXX="icx-cc --driver-mode=g++" LD=ld.lld AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib \
  CFLAGS="-O2 -fms-runtime-lib=dll $FP" CXXFLAGS="-O2 -fms-runtime-lib=dll $FP -std=c++17" \
  CPPBIN="$S/sqlcpp" \
  CPPFLAGS="-D_USE_MATH_DEFINES -DYY_NO_UNISTD_H -Dstrcasecmp=_stricmp -Dstrncasecmp=_strnicmp -I$ICONV/include -I$JSONC/include -I$PROJ/include -I$XML/include/libxml2" \
  LDFLAGS="$LINK_CRT $LIBDIRS $MATH -llibmmd" \
  LIBS="$RT" \
  "$SRC/configure" \
    --with-pgconfig="$S/pg_config" --with-geosconfig="$S/geos-config" --with-projdir="$PROJ" \
    --with-xml2config="$XML/bin/xml2-config" --with-jsondir="$JSONC" \
    --without-protobuf --without-raster --without-address-standardizer --without-interrupt-tests \
    --host=x86_64-w64-mingw32 --build=x86_64-w64-mingw32
  # the sources include ../postgis_config.h relative to themselves, an in-tree build's: the headers configure made
  # here go beside the sources, so a stale one from an earlier configure cannot shadow them
  for f in postgis_config.h postgis_revision.h; do if [ -f "$B/$f" ]; then cp "$B/$f" "$SRC/$f"; fi; done
}

# PostgreSQL's Windows port headers are on the include path only here: configure's probes break with them.
pmake() {
  CPATH="$(cygpath -m "$PG/include/server/port/win32_msvc");$(cygpath -m "$PG/include/server/port/win32")" \
  CCC_OVERRIDE_OPTIONS="+-DWIN32" \
  make CXX="icx-cc -fms-runtime-lib=dll -std=c++17 -x c++" CC="$S/icx-pgxs" \
    LDFLAGS="$LINK_CRT $LIBDIRS -L$PG/lib $MATH $RT -llibmmd -Wl,/STACK:4194304" \
    LIBTOOL="/bin/sh $B/libtool --tag=CC" "$@"     # libtool infers its tag from CC, which is overridden
}

build() {
  cd "$B"
  # postgis_revision.h is the top-level make's (utils/repo_revision.pl); the sources include it through postgis_config.h
  make postgis_revision.h
  for f in postgis_config.h postgis_revision.h; do if [ -f "$B/$f" ]; then cp "$B/$f" "$SRC/$f"; fi; done
  make -C liblwgeom liblwgeom.la
  make -C deps/flatgeobuf CXX="icx-cc -fms-runtime-lib=dll -std=c++17 -x c++"
  # libtool names the MSVC-format archive lwgeom.lib; PGXS links it by its MinGW name.
  cp liblwgeom/.libs/lwgeom.lib liblwgeom/.libs/liblwgeom.a
  # Directory by directory: the top level stops at the first that fails, utils (scripts Laplace does not use) builds
  # raster's upgrade scripts even without raster, and so does extensions as a whole: only the two extensions built.
  for d in libpgcommon postgis topology; do pmake -j"$(nproc)" -C $d all; done
  pmake -C extensions postgis_extension_helper.sql                     # the parent's generated helper the extensions include
  # the postgis extension's whole target also makes the upgrade scripts, which want raster's: the control file and the
  # install script are what CREATE EXTENSION reads
  pmake -C extensions/postgis postgis.control "sql/postgis--$(ver postgis).sql"
  pmake -j"$(nproc)" -C extensions/postgis_topology all
  # libtool's launcher wrappers for the loader programs fail to link (it builds them without LDFLAGS); the programs
  # themselves are in loader/.libs.
  pmake -j"$(nproc)" -k -C loader all || true
  for f in postgis/postgis-3.dll topology/postgis_topology-3.dll loader/.libs/shp2pgsql.exe loader/.libs/pgsql2shp.exe; do
    test -f "$f" || { echo "postgis.sh: $f was not built" >&2; exit 1; }
  done
}

install() {
  cd "$B"
  for d in postgis topology extensions/postgis_topology; do pmake -C $d install; done
  cp extensions/postgis/postgis.control "extensions/postgis/sql/postgis--$(ver postgis).sql" "$PG/share/extension/"
  cp loader/.libs/shp2pgsql.exe loader/.libs/pgsql2shp.exe "$PG/bin/"
  # The DLLs PostGIS loads, beside postgres.exe: Windows finds a backend module's dependencies there.
  for f in "$GEOS/bin/geos.dll" "$GEOS/bin/geos_c.dll" "$PROJ/bin/proj_9.dll" "$JSONC/bin/json-c.dll" \
           "$ICONV/bin/iconv.dll" "$D/sqlite/$(ver sqlite)/bin/sqlite3.dll" "$D/libtiff/$(ver libtiff)/bin/tiff.dll" \
           "$D/curl/$(ver curl)/bin/libcurl.dll"; do
    cp "$f" "$PG/bin/"
  done
}

[ $# -gt 0 ] || set -- configure build install
for step in "$@"; do "$step"; done
