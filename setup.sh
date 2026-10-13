#!/bin/bash
# The machine Laplace runs on, declared once and converged: the one step that needs root (Operations: Setup, Database).
#
#   sudo ./setup.sh            everything below, in order; each part looks at the state and makes only what is missing
#   sudo ./setup.sh access     one part, or several: volumes | packages | rights | kernel | deps | cluster | settings | access |
#                              appdb | backup | site | runtime | modular | agents | idlestop | report
#   sudo ./setup.sh machine    public declaration permissions only; no packages, database or service changes
#   sudo ./setup.sh secrets-stack  converge the existing hart-server Vaultwarden/OpenBao stack; not part of all
#   sudo ./setup.sh secrets-recover recover nginx and unseal existing Bao from its private escrow; no initialization
#   sudo ./setup.sh secrets-backup install the backup job only and run a checked backup; not part of all
#   sudo ./setup.sh secrets-client refresh the declared app DB credentials through this host's Bao AppRole; install timer
#   sudo ./setup.sh chess      the chess lab's engines, conductor, networks and books (chess/provision.sh); not part of all
#   sudo ./setup.sh shares     the SMB shares for the development machine (LAPLACE_SHARES); not part of all
#   sudo ./setup.sh landing    where other hosts' backups land (LAPLACE_LANDING, backup/landing.keys): part of all on the
#                              host that has that volume, passed over on one that does not
#   sudo LAPLACE_DROP=/data/pgdata ./setup.sh drop all
#                              the cluster dropped and made again, empty: never part of all, and named to be dropped
#
# Nothing here is a sequence of patches. Each part is a set: the volumes there are to be, the packages, the settings,
# the access rules; the part compares the set with the machine and closes the difference. Running it again on a
# finished machine converges its declared configuration and verifies the runtime. What it did is kept under
# $LAPLACE_WORK/logs/root and the runtime receipt directory. Every name of this
# machine's (paths, users, groups, volumes, the service, the network) is a variable of laplace.env, so another machine
# declares its own.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [[ ${1:-} == secrets-recover ]]; then
  shift
  exec bash "$here/secrets/recover.sh" "$@"
fi
if [[ ${1:-} == nginx-repair ]]; then
  shift
  exec bash "$here/network/repair-nginx.sh" "$@"
fi
if [[ ${1:-} == secrets-protection ]]; then
  shift
  exec python3 "$here/secrets/protection.py" "$@"
fi
# Repair has its own complete preflight and host lock before any mutation.
if [[ ${1:-} == repair ]]; then
  shift
  exec python3 "$here/installation/repair.py" "$@"
fi
if [[ ${1:-} == postgres ]]; then
  shift
  exec python3 "$here/installation/postgres-installation.py" "$@"
fi
if [[ ${1:-} == runtime && ( $# == 1 || ${2:-} == --* ) ]]; then
  shift
  exec python3 "$here/installation/runtime.py" "$@"
fi
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
. "$here/machine-config.sh"
machine_config_permissions
if [[ $# == 1 && $1 == machine ]]; then
  echo '/etc/laplace: 755; machine.env: 644 when present; credentials unchanged'
  exit 0
fi
. "$here/laplace.env"
. "$here/installation/setup-flow.sh"
# A database connection is a consumer, not a request to create another cluster.
# Monorepo workload setup is owned by Laplace/deploy/linux/site-host.sh.
if [[ -n ${LAPLACE_APP_PGDATA:-} && $LAPLACE_APP_PGDATA != "$LAPLACE_PGDATA" ]]; then
  echo 'Application databases must use the selected PostgreSQL cluster; reconcile machine.env before setup.' >&2
  exit 2
fi
setup_runtime_verified=0
op=${SUDO_USER:-$(id -un)}; ophome=$(getent passwd "$op" | cut -d: -f6)
PGDATA=$LAPLACE_PGDATA; PGWAL=$LAPLACE_PGWAL; PGTEMP=$LAPLACE_PGTEMP; PGUSER=$LAPLACE_PGUSER; PGBIN=$LAPLACE_PG_DIR/bin; PREFIX=$LAPLACE_PREFIX; SERVICE=$LAPLACE_PGSERVICE
as_pg(){ su "$PGUSER" -c "$*" </dev/null; }                                     # as the server's user; never reads our stdin
as_op(){ su -s /bin/bash "$op" -c "$*" </dev/null; }                              # as whoever ran this (an agent has no shell of its own)
q(){ as_pg "$PGBIN/psql -X -h /tmp -d postgres -Atc \"$1\""; }                  # one statement, its value
run(){ as_pg "$PGBIN/psql -X -h /tmp -d postgres -qc \"$1\"" >/dev/null; }        # one statement, done
# the server accepting connections, however long its recovery takes; a server that stops on the way is a failure
ready(){ for _ in $(seq 7200); do as_pg "$PGBIN/pg_isready -q -h /tmp" && return 0
           systemctl is-active -q "$SERVICE.service" || { journalctl -u "$SERVICE.service" -n 15 --no-pager; echo "$SERVICE.service stopped before it accepted connections"; exit 1; }
           sleep 1; done; echo "$SERVICE.service did not accept connections in two hours"; exit 1; }
# an ingest of the database laplace.env names holds its lock (ingest.sh)
ingesting(){ local db l; db=$(echo "$LAPLACE_CONNINFO" | sed -n 's/.*dbname=\([^ ]*\).*/\1/p'); l=$LAPLACE_LOCKS/ingest-${db:-default}.lock
             [ -e "$l" ] && ! flock -n "$l" true; }
mkdir -p "$LAPLACE_WORK/logs/root"; chown "$op" "$LAPLACE_WORK/logs/root"
log=$LAPLACE_WORK/logs/root/setup-$(date -u +%Y%m%dT%H%M%SZ).log; exec > >(tee "$log") 2>&1
say(){ printf '  %-46s %s\n' "$1" "$2"; }
part(){ echo; echo "=== $1   $(date -u +%H:%M:%S)"; }

# ------------------------------------------------------------------------------------------------------- the sets
# Volumes: $LAPLACE_VOLUMES (laplace.env): vg lv size fs mount. An existing volume is never resized or reformatted; a
# missing one is made. Anything not Laplace's is not there.
VOLUMES=$LAPLACE_VOLUMES
# Packages from the distribution: the build tools and the libraries PostgreSQL, PostGIS, PROJ and GDAL are built on.
PACKAGES="build-essential cmake ninja-build meson pkg-config flex bison liburing-dev libssl-dev liblz4-dev libzstd-dev
libreadline-dev zlib1g-dev libxml2-dev libsqlite3-dev libtiff-dev libcurl4-openssl-dev libprotobuf-c-dev
protobuf-c-compiler libjson-c-dev libeigen3-dev xfsprogs lvm2 openssl linux-tools-$(uname -r) linux-tools-generic
sqlite3 autoconf automake libtool libgmp-dev libmpfr-dev curl ca-certificates"   # linux-tools: perf for the running kernel; sqlite3: PROJ's build runs it; autotools: PostGIS's autogen; GMP, MPFR: PostGIS 3.6
# Dependencies built from source under $LAPLACE_SRC, in this order; each is known by the file it installs, and is
# cloned when its source is not there. name  proof  how  origin  branch
DEPS="
geos        $PREFIX/bin/geos-config             cmake      https://github.com/libgeos/geos.git              main
proj        $PREFIX/bin/projinfo                cmake      https://github.com/OSGeo/PROJ.git                master
gdal        $PREFIX/bin/gdal-config             cmake      https://github.com/OSGeo/gdal.git                master
spectra     $PREFIX/include/Spectra/SymEigsSolver.h   headers   https://github.com/yixuan/spectra.git      master
postgresql  $PGBIN/postgres                     configure  https://git.postgresql.org/git/postgresql.git    REL_18_STABLE
postgis     $LAPLACE_PG_DIR/share/extension/postgis.control   postgis   https://git.osgeo.org/gitea/postgis/postgis.git   master
blake3      $LAPLACE_DEPSRC/blake3/c/blake3.h   source     https://github.com/BLAKE3-team/BLAKE3.git        master
core-math   $LAPLACE_DEPSRC/core-math/src       source     https://gitlab.inria.fr/core-math/core-math.git  master
tree-sitter $LAPLACE_DEPSRC/tree-sitter/lib/src/lib.c   source   https://github.com/tree-sitter/tree-sitter.git   master
Fathom      $LAPLACE_DEPSRC/Fathom/src/tbprobe.c   source   https://github.com/jdart1/Fathom.git              master
"
# The server's settings (Database.md). tune-pg.sh holds the declaration and the check.
# CI applies it on every deploy, as the role. This script applies the same set when a
# restart needs root.
# shellcheck source=tune-pg.sh
. "$here/tune-pg.sh"
# Who may connect, and how: the whole file, not a line added to whatever is there.
HBA="# Laplace (setup.sh). Local: the server's own user and the operator, over the socket. The network: laplace and postgres, scram over TLS; postgres also by password from the host itself.
include_if_exists pg_hba.operator.conf
local     all   $PGUSER                           peer
local     all   $LAPLACE_ROLE                     peer map=laplace
host      all   $LAPLACE_ROLE  127.0.0.1/32       scram-sha-256
host      all   $LAPLACE_ROLE  ::1/128            scram-sha-256
hostssl   all   $LAPLACE_ROLE  $LAPLACE_LAN       scram-sha-256
host      all   $PGUSER        127.0.0.1/32       scram-sha-256
host      all   $PGUSER        ::1/128            scram-sha-256
hostssl   all   $PGUSER        $LAPLACE_LAN       scram-sha-256
include_if_exists pg_hba.remote.conf
include_if_exists pg_hba.runtime.conf
include_if_exists pg_hba.modular.conf
hostnossl all   all            0.0.0.0/0          reject
"
# Who operates Laplace on this machine is the shared group: every member connects over the socket as $LAPLACE_ROLE,
# and has the role's password in ~/.pgpass. Not whoever happened to run this script.
operators(){ { getent group "$LAPLACE_GROUP" | cut -d: -f4 | tr , '\n'; echo "$LAPLACE_AGENT_USER"; echo "$PGUSER"; } | grep . | sort -u; }
ident(){ echo "# who connects over the socket as $LAPLACE_ROLE: the members of $LAPLACE_GROUP, the agent, the server's user"
         echo 'include_if_exists pg_ident.operator.conf'
         echo 'include_if_exists pg_ident.runtime.conf'
         echo 'include_if_exists pg_ident.modular.conf'
         operators | while read -r u; do printf 'laplace  %-20s %s\n' "$u" "$LAPLACE_ROLE"; done; }

# ------------------------------------------------------------------------------------------------------- the parts
volumes(){ part volumes
  echo "$VOLUMES" | while read -r vg lv size fs mnt _; do [ -n "$vg" ] || continue
    dev=/dev/$vg/$lv
    if [ "$vg" = gcs ]; then
      # A Cloud Storage bucket as a volume (the data on a cloud host): mounted read-only through gcsfuse with a file
      # cache on the local disk, so an ingest reads each file once from the bucket; the line names the bucket as the
      # volume, the size as the cache's bound (e.g. 20G), e.g. "gcs laplace-data-xxxx 20G gcsfuse $LAPLACE_DATA".
      if ! command -v gcsfuse >/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt gcsfuse-$(lsb_release -cs) main" > /etc/apt/sources.list.d/gcsfuse.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg > /usr/share/keyrings/cloud.google.asc
        apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q gcsfuse >/dev/null; say "$mnt" "gcsfuse installed"
      fi
      # the volume is a bucket, or a directory in one: "gcs laplace-data-xxxx/Data 20G gcsfuse $LAPLACE_DATA"
      bucket=${lv%%/*}; dir=${lv#"$bucket"}; dir=${dir#/}
      cache=/var/cache/laplace-gcsfuse/$(echo "$lv" | tr / -); install -d -m 755 "$cache" "$mnt"   # one cache per mount
      cache_mb=$(echo "$size" | awk '/G$/ {print $1 * 1024; next} /M$/ {print $1 + 0; next} {print 20480}')
      opts="ro,_netdev,allow_other,implicit_dirs,file_cache_max_size_mb=$cache_mb,cache_dir=$cache,metadata_cache_ttl_secs=3600,uid=$(id -u "$op"),gid=$(getent group "$LAPLACE_GROUP" | cut -d: -f3)${dir:+,only_dir=$dir}"
      grep -q "^$bucket $mnt gcsfuse $opts " /etc/fstab || { sed -i "\| $mnt gcsfuse |d" /etc/fstab; printf '%s %s gcsfuse %s 0 0\n' "$bucket" "$mnt" "$opts" >> /etc/fstab; say "$mnt" "added to fstab (bucket $bucket${dir:+, directory $dir})"; }
      findmnt -n "$mnt" >/dev/null || { mount "$mnt" >/dev/null 2>&1 && say "$mnt" "mounted" || say "$mnt" "DID NOT MOUNT: give the host's service account roles/storage.objectViewer on the bucket: gcloud storage buckets add-iam-policy-binding gs://$bucket --member=serviceAccount:<the host's> --role=roles/storage.objectViewer"; }
      say "$mnt" "$(findmnt -n -o SOURCE,FSTYPE "$mnt" 2>/dev/null || echo 'not mounted')"; continue
    fi
    if [ "$vg" = file ]; then
      # No volume group on this machine (a cloud host with one disk): the volume is a file, mounted through a loop
      # device, so what reads the mount table (tune-pg's WAL bound) sees a device of its own size.
      [ "$size" != ALL ] || { say "$mnt" "a file volume needs a size, not ALL: skipped"; continue; }
      img=/var/lib/laplace/volumes/$lv.img
      if [ ! -e "$img" ]; then install -d -m 700 /var/lib/laplace/volumes; fallocate -l "$size" "$img"; mkfs."$fs" -q "$img"; say "$mnt" "made $img $size $fs"; fi
      mkdir -p "$mnt"
      grep -q "^$img " /etc/fstab || { printf '%s  %s  %s  loop,noatime,nofail  0  0\n' "$img" "$mnt" "$fs" >> /etc/fstab; say "$mnt" "added to fstab"; }
      findmnt -n "$mnt" >/dev/null || { mount "$mnt"; say "$mnt" "mounted"; }
      say "$mnt" "$(findmnt -n -o SOURCE,SIZE,AVAIL "$mnt")"; continue
    fi
    if ! vgs "$vg" >/dev/null 2>&1; then say "$mnt" "volume group $vg is not on this machine: skipped"; continue; fi
    if [ ! -e "$dev" ]; then
      if [ "$size" = ALL ]; then lvcreate -l 100%FREE -n "$lv" "$vg" >/dev/null; else lvcreate -L "$size" -n "$lv" "$vg" >/dev/null; fi
      mkfs."$fs" -q "$dev"; say "$mnt" "made $vg/$lv $size $fs"
    fi
    uuid=$(blkid -s UUID -o value "$dev"); mkdir -p "$mnt"
    grep -q "UUID=$uuid" /etc/fstab || { printf 'UUID=%s  %s  %s  defaults,nofail  0  2\n' "$uuid" "$mnt" "$fs" >> /etc/fstab; say "$mnt" "added to fstab"; }
    findmnt -n "$mnt" >/dev/null || { mount "$mnt"; say "$mnt" "mounted"; }
    say "$mnt" "$(findmnt -n -o SOURCE,SIZE,AVAIL "$mnt")"
  done
  shared
}
# What the operator and the agent both read and write is the shared group's, set-group-id and group-writable, so
# neither ever meets a permission: sources, builds, work, dependencies; and the server's extension directories.
# The data is only read: its owner, group and modes are its owner's, and nothing here changes them.
shared(){
  getent group "$LAPLACE_GROUP" >/dev/null || return 0
  mkdir -p "$LAPLACE_SRC" "$LAPLACE_BUILD" "$LAPLACE_WORK" "$LAPLACE_DEPS"
  for d in "$LAPLACE_SRC" "$LAPLACE_BUILD" "$LAPLACE_WORK" "$LAPLACE_DEPS"; do
    chgrp -R "$LAPLACE_GROUP" "$d" 2>/dev/null || true; chmod -R g+rwX "$d" 2>/dev/null || true; find "$d" -type d -exec chmod g+s {} + 2>/dev/null || true
  done
  install -d "$LAPLACE_PG_DIR/lib" "$LAPLACE_PG_DIR/share/extension"; chgrp "$LAPLACE_PG_GROUP" "$LAPLACE_PG_DIR/lib" "$LAPLACE_PG_DIR/share/extension"; chmod 2775 "$LAPLACE_PG_DIR/lib" "$LAPLACE_PG_DIR/share/extension"
  # the locks: one deployment per database at a time, whoever runs it; the directory is on tmpfs, so it is declared to be made at every boot
  printf 'd %s 2775 root %s -\nz %s/* 0664 - %s -\n' "$LAPLACE_LOCKS" "$LAPLACE_GROUP" "$LAPLACE_LOCKS" "$LAPLACE_GROUP" > /etc/tmpfiles.d/laplace.conf; systemd-tmpfiles --create /etc/tmpfiles.d/laplace.conf
  say "shared trees" "group $LAPLACE_GROUP, set-group-id, group-writable"; say "$LAPLACE_PG_DIR/{lib,share/extension}" "group $LAPLACE_PG_GROUP"; say "locks" "$LAPLACE_LOCKS, at every boot"
}
packages(){ part packages
  missing=$(for p in $PACKAGES; do dpkg-query -W -f '${Status}\n' "$p" 2>/dev/null | grep -q "install ok installed" || echo "$p"; done)
  if [ -n "$missing" ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing; say "installed" "$(echo $missing)"; else say "packages" "all $(echo $PACKAGES | wc -w) present"; fi
  [ -e /opt/intel/oneapi/setvars.sh ] && say "Intel oneAPI" "present" || say "Intel oneAPI" "MISSING: install it from Intel (icx, MKL) and run setup.sh again"
  # CMake 3.24 or newer, 4.x for icx 2026 (Setup: Toolchain): the distribution's is older, so Kitware's release goes
  # under $PREFIX for everyone on the machine, the agents included
  have=0; [ -x "$PREFIX/bin/cmake" ] && have=$("$PREFIX/bin/cmake" --version | sed -n '1s/.* //p'); case $have in 3.2[4-9]*|3.[3-9]*|[4-9].*) say "CMake" "$have at $PREFIX/bin/cmake" ;; *)
    v=$(curl -fsSL https://api.github.com/repos/Kitware/CMake/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v$v/cmake-$v-linux-x86_64.tar.gz" | tar xz -C "$PREFIX" --strip-components=1 --exclude='*/doc' --exclude='*/man'
    say "CMake" "$("$PREFIX/bin/cmake" --version | sed -n '1s/.* //p') installed under $PREFIX" ;; esac
  id "$PGUSER" >/dev/null 2>&1 || { useradd -r -m -d "/var/lib/$PGUSER" -s /bin/bash "$PGUSER"; say "user $PGUSER" "made"; }
  # the users and groups: the server's user; the group the operator and the agent share; the group that installs extensions
  getent group "$LAPLACE_GROUP" >/dev/null || groupadd -r "$LAPLACE_GROUP"
  getent group "$LAPLACE_PG_GROUP" >/dev/null || groupadd -r "$LAPLACE_PG_GROUP"
  id "$LAPLACE_AGENT_USER" >/dev/null 2>&1 || useradd -r -d "$LAPLACE_AGENT_HOME" -s /usr/sbin/nologin -g "$LAPLACE_GROUP" "$LAPLACE_AGENT_USER"
  for u in "$op" "$LAPLACE_AGENT_USER"; do id -nG "$u" | tr ' ' '\n' | grep -qx "$LAPLACE_GROUP" || usermod -aG "$LAPLACE_GROUP" "$u"; id -nG "$u" | tr ' ' '\n' | grep -qx "$LAPLACE_PG_GROUP" || usermod -aG "$LAPLACE_PG_GROUP" "$u"; done
  say "group $LAPLACE_GROUP" "$(getent group "$LAPLACE_GROUP" | cut -d: -f4)"; say "group $LAPLACE_PG_GROUP" "$(getent group "$LAPLACE_PG_GROUP" | cut -d: -f4)"
}
hugepage_access_group(){
  local group
  group=$(sysctl -n vm.hugetlb_shm_group)
  if [ "$group" = 0 ]; then id -g "$PGUSER"
  elif id -G "$PGUSER" | tr ' ' '\n' | grep -qx "$group"; then printf '%s\n' "$group"
  else echo "vm.hugetlb_shm_group=$group excludes $PGUSER; refusing to replace another workload's access group" >&2; return 1; fi
}
kernel()( part kernel
  . "$here/operation-lock.sh"
  laplace_host_lock exclusive
  # huge pages: what the server says it needs, 3% over, from the shared_buffers declared above; takes effect at boot
  # and now, as far as free memory allows
  page_kb=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo)
  [ "${page_kb:-0}" -gt 0 ] || { echo 'Kernel does not expose a default huge page size' >&2; exit 1; }
  sb=$(declared | awk '$1=="shared_buffers"{print $2}' | tr -d MB)
  declared=$(((sb * 1024 * 103 / 100 + 131072 + page_kb - 1) / page_kb))
  need=$(q "SHOW shared_memory_size_in_huge_pages" 2>/dev/null || echo 0); [ "${need:-0}" -gt "$declared" ] || need=$declared
  want=$((need + need * 3 / 100))
  group=$(hugepage_access_group)
  printf 'vm.nr_hugepages = %s\nvm.hugetlb_shm_group = %s\nkernel.kptr_restrict = 0\nkernel.perf_event_paranoid = 0\n' "$want" "$group" > /etc/sysctl.d/60-laplace.conf   # the profilers see the kernel's symbols
  sysctl -q -p /etc/sysctl.d/60-laplace.conf; say "vm.nr_hugepages" "$want (the server needs $need)   reserved now: $(awk '/HugePages_Total/{print $2}' /proc/meminfo)"
  say "huge page access" "$PGUSER via OS group $group"
)
deps(){ part dependencies
  set +u; . /opt/intel/oneapi/setvars.sh >/dev/null 2>&1 || true; set -u
  # ICU 78 is a release, not a build: unicode-org's Linux binaries, unpacked under $LAPLACE_ICU_DIR (lib, include)
  if [ -d "$LAPLACE_ICU_DIR/lib" ]; then say "ICU 78 (Unicode 17)" "$LAPLACE_ICU_DIR"
  else
    url=https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-Ubuntu22.04-x64.tgz; t=$(mktemp -d)
    if curl -fsSL "$url" | tar xz -C "$t" && [ -d "$t/icu/usr/local/lib" ]; then
      install -d "$LAPLACE_ICU_DIR"; cp -a "$t/icu/usr/local/." "$LAPLACE_ICU_DIR/"; say "ICU 78 (Unicode 17)" "fetched into $LAPLACE_ICU_DIR"
    else say "ICU 78" "COULD NOT FETCH $url: unpack the release into $LAPLACE_ICU_DIR (lib, include); tier 0 is Unicode 17"; fi
    rm -rf "$t"
  fi
  # The loader finds ICU 78 and the compiler's runtime (libimf, libsvml, libintlc: everything icx built needs them)
  # without anyone's environment: the server's user, the agent and a systemd unit have none.
  printf '%s\n' "$LAPLACE_ICU_DIR/lib" > /etc/ld.so.conf.d/laplace-icu.conf
  rt=$(ls -d /opt/intel/oneapi/compiler/[0-9]*/lib 2>/dev/null | sort -V | tail -1)
  [ -n "$rt" ] && printf '%s\n' "$rt" > /etc/ld.so.conf.d/laplace-oneapi.conf
  ldconfig 2>/dev/null; say "loader" "ICU 78${rt:+, oneAPI runtime $rt}"
  # Each build's output is its own log under $LAPLACE_WORK/logs/root; a failure is said and the next dependency is
  # tried (the loop is a pipeline: without this, one failure ended it in silence).
  echo "$DEPS" | while read -r name proof how origin branch; do [ -n "$name" ] || continue
    src=$LAPLACE_DEPSRC/$name; b=$LAPLACE_WORK/$name; dlog=$LAPLACE_WORK/logs/root/dep-$name.log
    if [ -e "$proof" ]; then say "$name" "installed"; continue; fi
    [ -d "$src" ] || { as_op "git clone -q --depth 1 -b $branch $origin $src" || { say "$name" "could not clone $origin"; continue; }; }
    if ! { case $how in
      cmake)     cmake -S "$src" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DBUILD_TESTING=OFF && cmake --build "$b" && cmake --install "$b" && ldconfig ;;
      source)    ;;                                                        # built into Laplace by its own CMake
      headers)   install -d "$PREFIX/include/Spectra" && cp -a "$src/include/Spectra/." "$PREFIX/include/Spectra/" ;;
      configure) mkdir -p "$b" && ( cd "$b" && { [ -f config.status ] || CC=icx CXX=icpx "$src/configure" --prefix="$LAPLACE_PG_DIR" --with-icu --with-ssl=openssl --with-lz4 --with-zstd --with-liburing \
                   ICU_CFLAGS="-I$LAPLACE_ICU_DIR/include" ICU_LIBS="-L$LAPLACE_ICU_DIR/lib -licui18n -licuuc -licudata"; } \
                   && make -j"$cores" && make install ) \
                 && ln -sfn "$PGBIN/psql" "$PREFIX/bin/psql" && ln -sfn "$PGBIN/pg_config" "$PREFIX/bin/pg_config" ;;
      postgis)   { [ -x "$src/configure" ] || as_op "cd $src && ./autogen.sh"; } \
                 && mkdir -p "$b" && ( cd "$b" && { [ -f config.status ] || "$src/configure" --with-pgconfig="$PGBIN/pg_config" --with-geosconfig=$PREFIX/bin/geos-config --with-projdir=$PREFIX --with-gdalconfig=$PREFIX/bin/gdal-config; } \
                   && make -j"$cores" && make install ) && ldconfig ;;
    esac; } > "$dlog" 2>&1; then say "$name" "FAILED: $dlog"; continue; fi
    [ -e "$proof" ] && say "$name" "built and installed" || say "$name" "DID NOT INSTALL: $b ($dlog)"
  done
  # PostgreSQL's contrib modules Laplace uses, each known by its library: pg_stat_statements and auto_explain are
  # preloaded (the settings), pg_buffercache inspects the cache, pg_walinspect reads the log while an ingest runs,
  # file_fdw is what the monorepo's ops schema reads its log files through (db/migrations/*_ops_*.sql)
  for m in pg_stat_statements pg_buffercache auto_explain pg_walinspect file_fdw; do
    if [ -e "$LAPLACE_PG_DIR/lib/$m.so" ]; then say "contrib $m" "installed"; continue; fi
    [ -d "$LAPLACE_WORK/postgresql/contrib/$m" ] && make -C "$LAPLACE_WORK/postgresql/contrib/$m" install >/dev/null 2>&1
    [ -e "$LAPLACE_PG_DIR/lib/$m.so" ] && say "contrib $m" "built and installed" || say "contrib $m" "DID NOT INSTALL: PostgreSQL's build is not at $LAPLACE_WORK/postgresql"
  done
  shared
}
cluster(){ part cluster
  install -d -o "$PGUSER" -g "$PGUSER" -m 700 "$PGDATA" "$PGWAL" "$PGTEMP"
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    # initdb wants an empty directory and the WAL directory is a mount: initialise beside it, then move the cluster in
    stage=$(mktemp -d "$(dirname "$PGDATA")/pgdata-init.XXXX"); chown "$PGUSER" "$stage"
    as_pg "$PGBIN/initdb -D $stage --locale=C.UTF-8 --encoding=UTF8 --data-checksums" >/dev/null
    cp -a "$stage/pg_wal/." "$PGWAL/"; rm -rf "$stage/pg_wal"; cp -a "$stage/." "$PGDATA/"; rm -rf "$stage"
    [ "$PGWAL" = "$PGDATA/pg_wal" ] || { rm -rf "$PGDATA/pg_wal"; ln -s "$PGWAL" "$PGDATA/pg_wal"; }
    chown -R "$PGUSER:$PGUSER" "$PGDATA" "$PGWAL" "$PGTEMP"; say "cluster" "initialised in $PGDATA, WAL in $PGWAL"
  else say "cluster" "$(cat "$PGDATA/PG_VERSION") in $PGDATA"; fi
  chown "$PGUSER:$PGUSER" "$PGWAL" "$PGTEMP"; chmod 700 "$PGWAL" "$PGTEMP"
  cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=PostgreSQL on $PGDATA
After=network.target
RequiresMountsFor=$PGDATA $PGWAL $PGTEMP

[Service]
Type=exec
User=$PGUSER
Group=$PGUSER
Environment=PGDATA=$PGDATA
ExecStart=$PGBIN/postgres -D $PGDATA
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGINT
TimeoutStartSec=60
TimeoutStopSec=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable -q "$SERVICE.service"
  systemctl is-active -q "$SERVICE.service" || { systemctl reset-failed "$SERVICE.service" 2>/dev/null || true; systemctl start "$SERVICE.service"; }
  ready
  say "$SERVICE.service" "$(systemctl is-active "$SERVICE.service"), accepting connections"
  [ "$(q "SELECT count(*) FROM pg_tablespace WHERE spcname = 'pgtemp'")" = 1 ] || run "CREATE TABLESPACE pgtemp LOCATION '$PGTEMP'"
  say "tablespace pgtemp" "$PGTEMP"
  # the server's certificate, before ssl = on is declared: a server told to use TLS without one does not start
  [ -s "$PGDATA/server.crt" ] || { as_pg "openssl req -new -x509 -days 3650 -nodes -subj '/CN=$(hostname)' -keyout $PGDATA/server.key -out $PGDATA/server.crt 2>/dev/null && chmod 600 $PGDATA/server.key"; say "certificate" "made, 10 years"; }
}
# The cluster dropped, for cluster to make again: the server stopped and disabled, and everything in its data
# directory, its log's volume and its temporary volume removed. The volumes themselves stay as they are. Every
# database on the server is lost, so it is never part of all, it asks for the data directory by name, and it does
# not run under an ingest or on a volume that is not mounted.
# Rights: what an agent may do as root is nothing. Every sudo rule that names the agent's user is removed (agents.sh
# once gave it its own checkout's setup.sh, writable by the shared group: root for anyone in it); the runners' units
# are root's and read-only; the shared group holds people, root and the agent, never another service's account (it
# would get the role's password in its ~/.pgpass). What earlier set-ups left (LEGACY) is removed: units of clusters
# and services that are gone, the sudo rules and helpers that pointed at them, and the directories those rules would
# let the group create and run as root. /opt/laplace and the nginx site laplace are the monorepo's site again (site).
LEGACY_UNITS="laplace-postgresql.service laplace-refactor-postgresql.service laplace-lichess.service laplace-stripe.service laplace-pg-log-prune.service laplace-pg-log-prune.timer"
LEGACY_PATHS="/usr/local/libexec/laplace-managed-deploy /usr/local/libexec/laplace-service-control /var/lib/laplace-managed /var/lib/laplace-mcp /var/log/laplace-mcp /etc/nginx/sites-enabled/laplace-managed /etc/nginx/sites-available/laplace-managed /build"
LEGACY_USERS="laplace-lichess"
rights(){ part rights
  for f in /etc/sudoers.d/*; do [ -f "$f" ] || continue
    if grep -qE "^[^#]*\b$LAPLACE_AGENT_USER\b" "$f" || case $(basename "$f") in laplace-*) true ;; *) false ;; esac; then rm -f "$f"; say "sudo" "removed $f"; fi; done
  sudo -l -U "$LAPLACE_AGENT_USER" 2>/dev/null | grep -q "may run the following" && say "sudo" "STILL GRANTED to $LAPLACE_AGENT_USER: see sudo -l -U $LAPLACE_AGENT_USER" || say "sudo" "$LAPLACE_AGENT_USER: none"
  for u in /etc/systemd/system/actions.runner.*.service; do [ -f "$u" ] || continue; chown root:root "$u"; chmod 644 "$u"; done; say "runner units" "root's, 644"
  for m in $(getent group "$LAPLACE_GROUP" | cut -d: -f4 | tr , ' '); do uid=$(id -u "$m" 2>/dev/null || echo 0)
    [ "$m" = root ] || [ "$m" = "$LAPLACE_AGENT_USER" ] || [ "$uid" -ge 1000 ] || { gpasswd -d "$m" "$LAPLACE_GROUP" >/dev/null; say "group $LAPLACE_GROUP" "removed $m (a service's account)"; }; done
  for u in $LEGACY_UNITS; do [ -e "/etc/systemd/system/$u" ] || [ -e "/etc/systemd/system/$u.d" ] || continue
    systemctl disable --now -q "$u" 2>/dev/null || true; rm -rf "/etc/systemd/system/$u" "/etc/systemd/system/$u.d"; say "unit" "removed $u"; done
  systemctl daemon-reload
  for pth in $LEGACY_PATHS; do [ -e "$pth" ] || [ -L "$pth" ] || continue; rm -rf "$pth"; say "removed" "$pth"; done
  command -v nginx >/dev/null && nginx -t -q 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  for u in $LEGACY_USERS; do id "$u" >/dev/null 2>&1 && { userdel "$u" 2>/dev/null; say "user" "removed $u"; }; done
  # The one thing the runner has of root: the server restarted, for a setting that needs it (tune-pg.sh). The runner
  # writes $LAPLACE_LOCKS/restart-pg; root's unit restarts $SERVICE and nothing else, never while an ingest holds a lock.
  # No sudo: polkit 0.105 (Ubuntu 22.04) cannot grant one unit alone.
  cat > /usr/local/sbin/laplace-pg-restart <<SH
#!/bin/sh
for l in $LAPLACE_LOCKS/ingest-*.lock; do [ -e "\$l" ] || continue
  flock -n "\$l" true || { echo "an ingest holds \$l: $SERVICE not restarted"; exit 1; }; done
exec systemctl restart $SERVICE.service
SH
  chown root:root /usr/local/sbin/laplace-pg-restart; chmod 755 /usr/local/sbin/laplace-pg-restart
  printf '[Unit]\nDescription=Restart %s when tune-pg.sh asks, never under an ingest\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/laplace-pg-restart\n' "$SERVICE" \
    > /etc/systemd/system/laplace-pg-restart.service
  printf '[Unit]\nDescription=tune-pg.sh asks for %s to be restarted\n[Path]\nPathChanged=%s/restart-pg\n[Install]\nWantedBy=multi-user.target\n' "$SERVICE" "$LAPLACE_LOCKS" \
    > /etc/systemd/system/laplace-pg-restart.path
  systemctl daemon-reload; systemctl enable --now -q laplace-pg-restart.path
  say "restart" "the runner may ask for $SERVICE to be restarted (write $LAPLACE_LOCKS/restart-pg); nothing else"
  return 0
}
drop(){ part drop
  [ "${LAPLACE_DROP:-}" = "$PGDATA" ] || { say "drop" "REFUSED: name the cluster to drop: LAPLACE_DROP=$PGDATA"; exit 1; }
  ! ingesting || { say "drop" "REFUSED: an ingest is running"; exit 1; }
  systemctl disable -q "$SERVICE.service" 2>/dev/null || true; systemctl stop "$SERVICE.service" 2>/dev/null || true; systemctl reset-failed "$SERVICE.service" 2>/dev/null || true
  for d in "$PGDATA" "$PGWAL" "$PGTEMP"; do mountpoint -q "$d" || { say "drop" "REFUSED: $d is not mounted"; exit 1; }; done
  find "$PGWAL" "$PGTEMP" -mindepth 1 -delete
  find "$PGDATA" -mindepth 1 -maxdepth 1 ! -path "$PGWAL" -exec rm -rf {} +
  say "drop" "$PGDATA, $PGWAL and $PGTEMP emptied: cluster makes the cluster again"
}
settings()( part settings
  . "$here/operation-lock.sh"
  laplace_host_lock exclusive
  ! ingesting || { echo 'Cannot converge PostgreSQL settings while ingestion is running' >&2; exit 1; }
  # every setting is stated; the server itself says which of them changed and which need a restart
  tune_apply
  pending=$(q "SELECT string_agg(name, ', ') FROM pg_settings WHERE pending_restart")
  say "settings" "$(declared | grep -c .) declared, reloaded"
  huge_mode=$(declared | awk '$1=="huge_pages"{print $2}')
  # An unchanged huge_pages=try setting does not request a PostgreSQL restart
  # when setup has just made the kernel pool/access available. Converge actual use.
  if [ "$huge_mode" != off ] && [ "$(q "SHOW huge_pages_status")" != on ]; then
    # This runtime-computed value must be read from the serving postmaster.
    # postgres -C requires exclusive access to PGDATA for this parameter.
    need=$(q "SHOW shared_memory_size_in_huge_pages")
    free=$(awk '/^HugePages_Free:/{free=$2} /^HugePages_Rsvd:/{reserved=$2} END{print free-reserved}' /proc/meminfo)
    group=$(sysctl -n vm.hugetlb_shm_group)
    id -G "$PGUSER" | tr ' ' '\n' | grep -qx "$group" || {
      echo "Huge page access is not configured for $PGUSER (vm.hugetlb_shm_group=$group); run setup kernel settings" >&2; exit 1;
    }
    [ "$need" -gt 0 ] && [ "$free" -ge "$need" ] || {
      echo "Huge pages unavailable: PostgreSQL needs $need, unreserved free pages $free; no restart performed" >&2; exit 1;
    }
    pending="${pending:+$pending, }huge page adoption"
  fi
  if [ -n "$pending" ]; then
    systemctl restart "$SERVICE.service"; ready; say "restarted for" "$pending"
  fi
  tune_check
  [ "$huge_mode" = off ] || [ "$(q "SHOW huge_pages_status")" = on ] || {
    echo "PostgreSQL is serving but failed to adopt configured huge pages; inspect $SERVICE.service startup logs" >&2; exit 1;
  }
  q "SELECT '  '||rpad(name, 46)||current_setting(name) FROM pg_settings WHERE name IN ('shared_buffers','huge_pages_status','effective_cache_size','work_mem','maintenance_work_mem','io_method','max_wal_size','wal_buffers','listen_addresses','ssl') ORDER BY name"
)
access(){ part access
  [ "$(q "SELECT count(*) FROM pg_roles WHERE rolname = '$LAPLACE_ROLE'")" = 1 ] || run "CREATE ROLE $LAPLACE_ROLE LOGIN SUPERUSER"
  # the role's password: one canonical copy, root's, in /etc/laplace; adopted from an operator's ~/.pgpass when it
  # is the one the server accepts, made when none is; then written into every operator's ~/.pgpass. Never printed.
  install -d -m 755 /etc/laplace; canon=/etc/laplace/pgpass
  works(){ PGPASSWORD=$1 "$PGBIN/psql" -X "host=127.0.0.1 port=5432 user=$LAPLACE_ROLE dbname=postgres" -Atc 'SELECT 1' 2>/dev/null | grep -q 1; }
  pw=""; [ -s "$canon" ] && pw=$(sed -n "s/^[^:]*:[^:]*:[^:]*:$LAPLACE_ROLE:\(.*\)$/\1/p" "$canon" | head -1)
  if [ -z "$pw" ] || ! works "$pw"; then
    keep=$pw; pw=""; for u in $(operators); do h=$(getent passwd "$u" | cut -d: -f6); [ -s "$h/.pgpass" ] || continue
      for c in $(sed -n "s/^[^:]*:[^:]*:[^:]*:$LAPLACE_ROLE:\(.*\)$/\1/p" "$h/.pgpass"); do works "$c" && { pw=$c; say "role $LAPLACE_ROLE" "password adopted from $u"; break 2; }; done; done
    # a cluster made again has the role without a password: it is given the canonical one, so no client's copy breaks
    if [ -z "$pw" ] && [ -n "$keep" ]; then pw=$keep; run "ALTER ROLE $LAPLACE_ROLE PASSWORD '$pw'"; say "role $LAPLACE_ROLE" "password from $canon"; fi
    if [ -z "$pw" ]; then pw=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32); run "ALTER ROLE $LAPLACE_ROLE PASSWORD '$pw'"; say "role $LAPLACE_ROLE" "password made"; fi
    umask 077; printf '*:5432:*:%s:%s\n' "$LAPLACE_ROLE" "$pw" > "$canon"
  else say "role $LAPLACE_ROLE" "password in $canon"; fi
  for u in $(operators); do h=$(getent passwd "$u" | cut -d: -f6); [ -d "$h" ] || continue
    { [ ! -f "$h/.pgpass" ] || grep -v ":$LAPLACE_ROLE:" "$h/.pgpass" || true; cat "$canon"; } > "$h/.pgpass.setup"; mv -f "$h/.pgpass.setup" "$h/.pgpass"; chown "$u" "$h/.pgpass"; chmod 600 "$h/.pgpass"; done
  unset pw; say "~/.pgpass" "$(operators | tr '\n' ' ')"
  say "role $PGUSER" 'existing administrator credential retained; setup does not assign a default password'
  printf '%s' "$HBA" > "$PGDATA/pg_hba.conf.setup"; ident > "$PGDATA/pg_ident.conf.setup"
  cmp -s "$PGDATA/pg_hba.conf.setup" "$PGDATA/pg_hba.conf" || { cp -p "$PGDATA/pg_hba.conf" "$PGDATA/pg_hba.conf.before" 2>/dev/null || true; mv "$PGDATA/pg_hba.conf.setup" "$PGDATA/pg_hba.conf"; say "pg_hba.conf" "written"; }
  cmp -s "$PGDATA/pg_ident.conf.setup" "$PGDATA/pg_ident.conf" || { mv "$PGDATA/pg_ident.conf.setup" "$PGDATA/pg_ident.conf"; say "pg_ident.conf" "written"; }
  rm -f "$PGDATA/pg_hba.conf.setup" "$PGDATA/pg_ident.conf.setup"; chown "$PGUSER:$PGUSER" "$PGDATA/pg_hba.conf" "$PGDATA/pg_ident.conf"
  q "SELECT pg_reload_conf()" >/dev/null
  if command -v ufw >/dev/null && ufw status | grep -q "^Status: active"; then ufw status | grep -q "5432/tcp.*$LAPLACE_LAN" || { ufw allow from "$LAPLACE_LAN" to any port 5432 proto tcp >/dev/null; say "ufw" "5432/tcp from $LAPLACE_LAN"; }; fi
  q "SELECT '  '||rpad(type, 10)||rpad(array_to_string(user_name, ','), 10)||rpad(coalesce(address, 'socket'), 18)||auth_method||coalesce('   '||error, '') FROM pg_hba_file_rules ORDER BY rule_number"
}
# The monorepo's site (SaltyPatron/Laplace: the API and the SPA over the database laplace-mono, behind nginx): its
# directories, unit, restart path and nginx site are declared by the monorepo's own host script, run here as root.
# What that script and the site's build (deploy/linux/site.sh) need from the distribution is declared here first, with
# the package sources they come from: nginx; the .NET 10 SDK from Ubuntu's dotnet backports (Microsoft's feed has no
# .NET 10 for 22.04); Node 24 from NodeSource; the GitHub CLI (agents.sh registers runners with it) from GitHub.
SITE_PACKAGES="nginx dotnet-sdk-10.0 nodejs gh"
site_sources(){
  [ -e /etc/apt/sources.list.d/dotnet-ubuntu-backports-jammy.sources ] || [ -e /etc/apt/sources.list.d/dotnet-ubuntu-backports-*.list ] \
    || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q software-properties-common >/dev/null; add-apt-repository -y ppa:dotnet/backports >/dev/null 2>&1; say "source" "ppa:dotnet/backports"; }
  [ -e /etc/apt/sources.list.d/nodesource.list ] \
    || { curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1; say "source" "NodeSource (Node 24)"; }
  [ -e /etc/apt/sources.list.d/github-cli.list ] \
    || { curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
         echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
         say "source" "GitHub CLI"; }
}
# An application database is created inside the host's selected PostgreSQL cluster.
# Schema, runtime identities and credentials belong to the implementation installer.
appdb_cluster(){
  local name=${LAPLACE_APP_DBNAME:-}
  [[ -n "$name" ]] || return 0
  local port=${LAPLACE_APP_PGPORT:-$LAPLACE_PGPORT} socket=${LAPLACE_PGSOCKET:-/tmp}
  local data=${LAPLACE_APP_PGDATA:-$PGDATA}
  [[ "$data" == "$PGDATA" && "$port" == "$LAPLACE_PGPORT" ]] || {
    echo 'Application database must use the selected PostgreSQL cluster; select that cluster in machine.env.' >&2
    return 1
  }
  local actual
  actual=$(runuser -u "$PGUSER" -- "$PGBIN/psql" -X -w -h "$socket" -p "$port" -d postgres -At -v ON_ERROR_STOP=1 -c 'SHOW data_directory')
  [[ "$(readlink -f "$actual")" == "$(readlink -f "$PGDATA")" ]] || { echo 'Connected PostgreSQL data directory differs from the declaration' >&2; return 1; }
  runuser -u "$PGUSER" -- "$PGBIN/psql" -X -w -h "$socket" -p "$port" -d postgres -v ON_ERROR_STOP=1 -v name="$name" -v owner="$LAPLACE_ROLE" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'owner')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name')
\gexec
SELECT datname, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = :'name';
SQL
  say "application database $name" "uses $SERVICE, $PGDATA; credentials unchanged"
}
# A host that is started for a job and pays by the minute (hart-cloud) stops itself when nothing has run on it for
# LAPLACE_IDLE_STOP_MINUTES (its machine.env): no runner job (a Runner.Worker process), no ingest, deploy or build, no
# login session, and the machine up for at least that long. Powering off a Compute Engine instance from inside is the
# same as stopping it: the disk stays, the pipeline starts it again for the next job. Hosts without the declaration
# skip the part.
idlestop(){ part "idle stop"
  local m=${LAPLACE_IDLE_STOP_MINUTES:-}; [ -n "$m" ] || { say "idle stop" "none declared (LAPLACE_IDLE_STOP_MINUTES): skipped"; return 0; }
  [[ "$m" =~ ^[0-9]+$ && "$m" -ge 1 ]] || { echo 'Idle minutes must be positive' >&2; return 2; }
  install -m 755 "$here/cloud/idle-stop.py" /usr/local/sbin/laplace-idle-stop.new
  mv -f /usr/local/sbin/laplace-idle-stop.new /usr/local/sbin/laplace-idle-stop
  chmod 755 /usr/local/sbin/laplace-idle-stop
  printf '[Unit]\nDescription=Laplace: stop this host when idle for %s minutes\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/laplace-idle-stop --minutes %s\n' "$m" "$m" > /etc/systemd/system/laplace-idle-stop.service
  printf '[Unit]\nDescription=Laplace: idle check every five minutes\n[Timer]\nOnBootSec=5min\nOnUnitActiveSec=5min\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/laplace-idle-stop.timer
  systemctl daemon-reload; systemctl enable -q --now laplace-idle-stop.timer
  say "idle stop" "after $m idle minutes; $(systemctl is-active laplace-idle-stop.timer); next $(systemctl show -p NextElapseUSecRealtime --value laplace-idle-stop.timer)"
}
# Business continuity: a host that holds databases (LAPLACE_BACKUP_DATABASES in its machine.env, e.g. "laplace laplace-mono"
# on the substrate host, "laplace-app" on the hosting host) dumps each of them nightly with pg_dump -Fc, proves the dump
# readable with pg_restore --list, and ships it over the tailnet to the landing LAPLACE_BACKUP_TARGET (user@host:, the
# landing part on hart-server: setup.sh landing), by rsync with the host's own key /etc/laplace/backup.key, made here; its
# public half /etc/laplace/backup.pub is declared in backup/landing.keys, which is what the landing authorizes. The landing
# is write-only for a sender (rrsync -wo into the sender's own directory): paths are relative to it, nothing is listed,
# read back or deleted there, so the dump is proven before it ships and retention on the landing is the landing's own
# timer. LAPLACE_BACKUP_KEEP_DAYS (default 30) dumps are kept locally under /var/backups/laplace. The server's own binaries
# are used (LAPLACE_PG_DIR; LAPLACE_BACKUP_PGBIN/PGPORT for the application cluster). Hosts without the declaration skip the
# part. A restore is proven by restoring into a scratch database on another host, which is an operation, not this part.
backup(){ part backup
  local dbs=${LAPLACE_BACKUP_DATABASES:-}; [ -n "$dbs" ] || { say "backup" "none declared (LAPLACE_BACKUP_DATABASES): skipped"; return 0; }
  local target=${LAPLACE_BACKUP_TARGET:-}; [ -n "$target" ] || { say "backup" "no landing declared (LAPLACE_BACKUP_TARGET): skipped"; return 0; }
  local pgbin=${LAPLACE_BACKUP_PGBIN:-$LAPLACE_PG_DIR/bin} port=${LAPLACE_BACKUP_PGPORT:-5432} keep=${LAPLACE_BACKUP_KEEP_DAYS:-30} dir=/var/backups/laplace
  install -d -m 750 -o "$PGUSER" -g "$PGUSER" "$dir"
  install -d -m 755 /etc/laplace
  [ -s /etc/laplace/backup.key ] || { ssh-keygen -q -t ed25519 -N '' -C "laplace-backup@$(hostname)" -f /etc/laplace/backup.key; mv -f /etc/laplace/backup.key.pub /etc/laplace/backup.pub; say "key" "made: declare /etc/laplace/backup.pub in backup/landing.keys"; }
  [ -s /etc/laplace/backup.pub ] || mv -f /etc/laplace/backup.key.pub /etc/laplace/backup.pub 2>/dev/null || true
  chown "$PGUSER" /etc/laplace/backup.key /etc/laplace/backup.pub; chmod 600 /etc/laplace/backup.key; chmod 644 /etc/laplace/backup.pub
  cat > /usr/local/sbin/laplace-backup <<EOS
#!/bin/bash
# Laplace (setup.sh backup): dump, prove, ship. Declared, not hand-made. Runs as $PGUSER.
set -euo pipefail
dir=$dir; pgbin=$pgbin; port=$port; keep=$keep; target=$target; host=\$(hostname); stamp=\$(date -u +%Y%m%dT%H%M%SZ); rc=0
for db in $dbs; do
  f="\$dir/\$host-\$db-\$stamp.dump"
  if "\$pgbin/pg_dump" -p "\$port" -Fc -f "\$f" "\$db" && "\$pgbin/pg_restore" --list "\$f" > /dev/null; then
    sha256sum "\$f" > "\$f.sha256"; logger -t laplace-backup "\$db: \$(stat -c %s "\$f") bytes, readable, \$f"
  else logger -t laplace-backup "\$db: DUMP FAILED"; rm -f "\$f" "\$f.sha256"; rc=1; continue; fi
  if rsync -q -e "ssh -i /etc/laplace/backup.key -o BatchMode=yes -o StrictHostKeyChecking=accept-new" "\$f" "\$f.sha256" "\$target"; then
    logger -t laplace-backup "\$db: shipped to \$target (the landing's directory for this host)"
  else logger -t laplace-backup "\$db: NOT SHIPPED to \$target (kept locally)"; rc=1; fi
done
find "\$dir" -name '*.dump*' -mtime +"\$keep" -delete
exit \$rc
EOS
  chmod 755 /usr/local/sbin/laplace-backup
  printf '[Unit]\nDescription=Laplace: dump, prove and ship the databases %s\n[Service]\nType=oneshot\nUser=%s\nExecStart=/usr/local/sbin/laplace-backup\n' "$dbs" "$PGUSER" > /etc/systemd/system/laplace-backup.service
  printf '[Unit]\nDescription=Laplace: nightly backup\n[Timer]\nOnCalendar=*-*-* 03:30:00\nRandomizedDelaySec=10min\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/laplace-backup.timer
  systemctl daemon-reload; systemctl enable -q --now laplace-backup.timer
  say "backup" "$dbs nightly at 03:30 UTC to $target, $keep days kept under $dir; $(systemctl is-active laplace-backup.timer)"
  say "key" "$(hostname)  $(cut -d' ' -f1,2 /etc/laplace/backup.pub)   (the line for backup/landing.keys)"
}
site(){ part site
  site_sources
  missing=$(for p in $SITE_PACKAGES; do dpkg-query -W -f '${Status}\n' "$p" 2>/dev/null | grep -q "install ok installed" || echo "$p"; done)
  if [ -n "$missing" ]; then apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing >/dev/null; say "installed" "$(echo $missing)"; else say "site packages" "all present"; fi
  say "site toolchain" "dotnet $(dotnet --version 2>/dev/null || echo MISSING), node $(node --version 2>/dev/null || echo MISSING), nginx $(nginx -v 2>&1 | sed 's|.*/||'), gh $(gh --version 2>/dev/null | sed -n '1s/.* \([0-9.]*\) .*/\1/p')"
  m=${LAPLACE_MONOREPO:-$LAPLACE_SRC/Laplace}; s=$m/deploy/linux/site-host.sh
  [ -f "$s" ] || { say "site" "no $s: git clone https://github.com/$LAPLACE_GITHUB/Laplace $m"; return 0; }
  bash "$s"
}
# The repositories' agents: one runner for every repository with a self-hosted workflow (agents.sh, which fails its
# status when one has none).
agents(){ part agents; SUDO_USER=$op bash "$here/agents.sh" all; }
# The chess lab's conventional reference (dependencies.tsv's chess rows): Stockfish built with profile-guided
# optimization, fastchess, Ordo, Lc0 with CUDA where there is an NVIDIA GPU, Lc0's networks and the opening suites,
# built and fetched as the operator by chess/provision.sh at $LAPLACE_CHESS_JOBS cores. Not part of all: a database
# host needs none of it, and it is named to be run.
chess(){ part chess
  as_op "LAPLACE_CHESS_JOBS=${LAPLACE_CHESS_JOBS:-2} $here/chess/provision.sh" || say "chess" "INCOMPLETE: $LAPLACE_WORK/chess-build"
  # the programs on everyone's PATH, which only root may link
  pending=$LAPLACE_WORK/chess-build/links.pending
  if [ -s "$pending" ]; then while IFS=$'\t' read -r target name; do ln -sfn "$target" "$PREFIX/bin/$name"; say "$PREFIX/bin/$name" "-> $target"; done < "$pending"; rm -f "$pending"; fi
  as_op "$here/chess/provision.sh report"
}
# The machine's shares (LAPLACE_SHARES) for the development machine, which reaches them by UNC path with its own
# credential (setup.ps1 shares there checks them): plain SMB 3 for one user, from the LAN only, served by smbd alone (no
# NetBIOS: Windows finds the machine through DNS), with ufw's 445/tcp rules when ufw is active. The whole smb.conf is
# declared, not lines added to whatever is there; the distribution's original is kept as smb.conf.orig. A changed
# configuration is reloaded, never restarted, so a copy running over a share is not cut off. The SMB password is the
# operator's to type when the user has none (smbpasswd asks); nothing here writes or prints it. Not part of all: a
# database host needs none of it, and it is named to be run.
SMB_LL6=fe80::/10
smbconf(){
  cat <<EOF
# Laplace (setup.sh shares): the shares for the development machine. The distribution's original is smb.conf.orig.
[global]
   workgroup = WORKGROUP
   server string = $(hostname)
   server role = standalone server
   server min protocol = SMB3
   smb encrypt = desired
   hosts allow = 127.0.0.1 ::1 $LAPLACE_LAN $LAPLACE_SHARE_LAN6 $SMB_LL6
   hosts deny = 0.0.0.0/0
   interfaces = lo $LAPLACE_SHARE_IF
   bind interfaces only = yes
   map to guest = never
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   # large sequential copies over 1 GbE
   use sendfile = yes
   aio read size = 1
   aio write size = 1
EOF
  echo "$LAPLACE_SHARES" | while read -r name path _; do [ -n "$name" ] || continue
    printf '\n[%s]\n   path = %s\n   valid users = %s\n   read only = no\n   force user = %s\n   create mask = 0664\n   directory mask = 2775\n' \
      "$name" "$path" "$LAPLACE_SHARE_USER" "$LAPLACE_SHARE_USER"; done
}
shares(){ part shares
  u=$LAPLACE_SHARE_USER; conf=/etc/samba/smb.conf; changed=0
  id "$u" >/dev/null 2>&1 || { say "shares" "REFUSED: no user $u (LAPLACE_SHARE_USER)"; return 0; }
  dpkg-query -W -f '${Status}\n' samba 2>/dev/null | grep -q "install ok installed" || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q samba >/dev/null; say "samba" "installed"; }
  say "samba" "$(smbd --version)"
  # each share's folder: a mount that is there, or a folder under one, made; the top folder the user's (the top only:
  # what is already inside keeps its owner)
  echo "$LAPLACE_SHARES" | while read -r name path _; do [ -n "$name" ] || continue
    if [ ! -d "$path" ]; then
      parent=$(dirname "$path")
      if [ "$parent" != / ] && [ -d "$parent" ]; then install -d -o "$u" -g "$u" -m 2775 "$path"; say "$path" "made"
      else say "[$name] $path" "MISSING: not mounted (volumes)"; continue; fi
    fi
    [ "$(stat -c %U "$path")" = "$u" ] || { chown "$u:$u" "$path"; say "$path" "given to $u"; }
    mountpoint -q "$path" || [ "$(stat -c %a "$path")" = 2775 ] || { chmod 2775 "$path"; say "$path" "mode 2775"; }
    say "[$name] $path" "$(stat -c '%U:%G %a' "$path")"
  done
  [ -f "$conf.orig" ] || [ ! -f "$conf" ] || cp -a "$conf" "$conf.orig"
  smbconf > "$conf.setup"
  if cmp -s "$conf.setup" "$conf"; then rm -f "$conf.setup"; say "smb.conf" "as declared"
  elif testparm -s "$conf.setup" >/dev/null 2>&1; then mv -f "$conf.setup" "$conf"; changed=1; say "smb.conf" "written"
  else rm -f "$conf.setup"; say "smb.conf" "NOT WRITTEN: the declaration does not pass testparm -s"; return 0; fi
  if pdbedit -L 2>/dev/null | grep -q "^$u:"; then say "SMB user $u" "present (sudo smbpasswd $u changes the password)"
  elif [ -t 0 ]; then echo "  the SMB password for $u (what Windows asks for):"; smbpasswd -a "$u"; say "SMB user $u" "made"
  else say "SMB user $u" "MISSING: from a terminal, sudo smbpasswd -a $u"; fi
  # ufw says when a rule is already there ("Skipping adding existing rule"): only a rule it adds is reported as added
  if command -v ufw >/dev/null && ufw status | grep -q "^Status: active"; then
    for src in "$LAPLACE_LAN" "$LAPLACE_SHARE_LAN6"; do
      out=$(ufw allow from "$src" to any port 445 proto tcp comment 'SMB from the LAN' 2>&1)
      case $out in *Skipping*) say "ufw 445/tcp from $src" "present" ;; *) say "ufw 445/tcp from $src" "added" ;; esac; done
    out=$(ufw allow in on "$LAPLACE_SHARE_IF" from "$SMB_LL6" to any port 445 proto tcp comment 'SMB from the LAN (link-local)' 2>&1)
    case $out in *Skipping*) say "ufw 445/tcp from $SMB_LL6 on $LAPLACE_SHARE_IF" "present" ;; *) say "ufw 445/tcp from $SMB_LL6 on $LAPLACE_SHARE_IF" "added" ;; esac
  else say "firewall" "ufw not active: hosts allow alone limits SMB to the LAN"; fi
  systemctl is-enabled -q smbd || { systemctl enable -q smbd; say "smbd" "enabled"; }
  if ! systemctl is-active -q smbd; then systemctl start smbd; say "smbd" "started"
  elif [ "$changed" = 1 ]; then systemctl reload smbd
    say "smbd" "reloaded; interfaces take effect at its next restart (sudo systemctl restart smbd, when no copy is running)"; fi
  if systemctl is-enabled -q nmbd 2>/dev/null || systemctl is-active -q nmbd 2>/dev/null; then systemctl disable --now -q nmbd; say "nmbd" "stopped and disabled"; fi
  say "smbd" "$(systemctl is-active smbd), $(ss -ltn | grep -q ':445 ' && echo 'listening on :445' || echo 'NOT LISTENING on :445')"
  say "shares" "$(echo "$LAPLACE_SHARES" | awk -v h="$(hostname)" 'NF {printf "\\\\%s\\%s  ", h, $1}')"
}
# Where other hosts' backups land (part of all where the volume is): the host with LAPLACE_LANDING's volume takes them over ssh from
# the hosts backup/landing.keys names, each under its own directory and write-only (rrsync -wo: a sender cannot read,
# change or remove what is there, its own earlier dumps included, so a host that is taken over cannot destroy its
# backups). The directory is on a volume of its own, never the system's: an array that is not mounted is refused, not
# filled in beside the system. Retention is this host's (the sender has no say): a daily timer removes what is older
# than LAPLACE_LANDING_KEEP days, and always keeps a host's newest LAPLACE_LANDING_MIN files whatever their age.
landing(){ part landing
  L=$LAPLACE_LANDING; U=$LAPLACE_LANDING_USER; keys=$here/backup/landing.keys
  [ -n "$L" ] || { say "landing" "LAPLACE_LANDING is empty: nothing lands here"; return; }
  command -v rrsync >/dev/null || { echo "rrsync is not installed: the rsync package brings it"; exit 1; }
  # asked for by name, a host without that volume is an error; as a part of all it is a host that is not the landing host
  up=$(dirname "$L")
  if [ ! -d "$up" ] || [ "$(stat -c %d "$up")" = "$(stat -c %d /)" ]; then
    if [ "${landing_of_all:-}" = 1 ]; then say "landing" "not here: $up is no volume of its own on this host (the landing host is the one that has it)"; return; fi
    echo "$up is not a mounted volume of its own: the backup volume is not there, and nothing is written beside the system"; exit 1; fi
  id "$U" >/dev/null 2>&1 || { useradd --system --home-dir "$L" --no-create-home --shell /bin/sh "$U"; say "user" "made $U (no password; ssh by key, to rrsync only)"; }
  passwd -l "$U" >/dev/null 2>&1 || true
  install -d -o root -g root -m 0755 "$L" "$L/.ssh"
  : > "$L/.ssh/authorized_keys.new"; n=0
  while read -r host type key _; do case $host in ''|\#*) continue ;; esac
    case $host in *[!A-Za-z0-9._-]*) echo "landing.keys: '$host' is not a host name"; exit 1 ;; esac
    case $type in ssh-ed25519|sk-ssh-ed25519@openssh.com) ;; *) echo "landing.keys: $host's key is $type, not ed25519"; exit 1 ;; esac
    install -d -o "$U" -g "$U" -m 0750 "$L/$host"
    printf 'restrict,command="%s -wo %s" %s %s %s\n' "$(command -v rrsync)" "$L/$host" "$type" "$key" "$host" >> "$L/.ssh/authorized_keys.new"
    n=$((n + 1)); say "$host" "lands in $L/$host ($(find "$L/$host" -type f 2>/dev/null | wc -l) files, $(du -sh "$L/$host" 2>/dev/null | cut -f1))"
  done < "$keys"
  chmod 0644 "$L/.ssh/authorized_keys.new"; mv -f "$L/.ssh/authorized_keys.new" "$L/.ssh/authorized_keys"
  # a directory no key names any more is kept and said: what landed is not removed because a line was
  for d in "$L"/*/; do [ -d "$d" ] || continue; h=$(basename "$d"); grep -q " $h\$" "$L/.ssh/authorized_keys" || say "$h" "no key in landing.keys any more: its directory is kept, nothing more lands"; done
  cat > /usr/local/libexec/laplace-landing-prune <<PRUNE
#!/bin/sh
# Retention on the landing host (setup.sh landing): older than $LAPLACE_LANDING_KEEP days goes, a host's newest $LAPLACE_LANDING_MIN files stay.
for d in "$L"/*/; do [ -d "\$d" ] || continue
  find "\$d" -type f -printf '%T@ %p\n' | sort -rn | tail -n +$((LAPLACE_LANDING_MIN + 1)) | cut -d' ' -f2- | while IFS= read -r f; do
    [ -n "\$(find "\$f" -mtime +$LAPLACE_LANDING_KEEP)" ] && { rm -f -- "\$f"; echo "removed \$f"; }; done
  find "\$d" -mindepth 1 -type d -empty -delete
done
PRUNE
  chmod 0755 /usr/local/libexec/laplace-landing-prune
  printf '[Unit]\nDescription=Retention of the backups landed on this host (%s: %s days, the newest %s of a host always)\n\n[Service]\nType=oneshot\nExecStart=/usr/local/libexec/laplace-landing-prune\n' "$L" "$LAPLACE_LANDING_KEEP" "$LAPLACE_LANDING_MIN" > /etc/systemd/system/laplace-landing-prune.service
  printf '[Unit]\nDescription=Daily retention of landed backups\n\n[Timer]\nOnCalendar=*-*-* 05:30:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/laplace-landing-prune.timer
  systemctl daemon-reload; systemctl enable -q --now laplace-landing-prune.timer
  say "accepts" "$n host(s) of backup/landing.keys, as $U, by key, to rrsync -wo only"
  say "retention" "$LAPLACE_LANDING_KEEP days, the newest $LAPLACE_LANDING_MIN of a host always; $(systemctl is-active laplace-landing-prune.timer) daily at 05:30"
  say "room" "$(df -h --output=avail,pcent "$L" | tail -1 | awk '{print $1" free, "$2" used"}') on $(df --output=target "$L" | tail -1)"
}

secrets-stack(){ part "secrets stack"; bash "$here/secrets/install.sh"; }
secrets-backup(){ part "secrets backups"; bash "$here/secrets/install-backup.sh"; }
secrets-client(){ part "OpenBao application database credentials"
  [[ -n ${LAPLACE_APP_DBNAME:-} ]] || { echo 'No application database declared on this host'; return 1; }
  local host=${LAPLACE_BAO_APPDB_HOST:-$(hostname -s)} credentials=${LAPLACE_BAO_CREDENTIALS:-/etc/laplace/approle.json}
  local connect_host=${LAPLACE_APP_PGHOST:-127.0.0.1} u h
  [[ -r $credentials ]] || { echo "Host AppRole credentials required at $credentials"; return 1; }
  local destinations=(/etc/laplace/pgpass)
  for u in $(operators); do h=$(getent passwd "$u" | cut -d: -f6); [[ ! -f $h/.pgpass ]] || destinations+=("$h/.pgpass"); done
  # Validate the record and DB authentication before installing recurring work.
  bash "$here/secrets/appdb-sync.sh" "$host" "$credentials" "$connect_host" "${destinations[@]}"
  install -d -m 755 /usr/local/libexec
  install -m 755 "$here/secrets/appdb-sync.sh" /usr/local/libexec/laplace-appdb-secrets
  {
    printf '#!/bin/bash\nset -euo pipefail\nexport BAO_ADDR=%q\nexec /usr/local/libexec/laplace-appdb-secrets ' "${BAO_ADDR:-https://openbao.hartonomous.com}"
    printf '%q ' "$host" "$credentials" "$connect_host" "${destinations[@]}"
    printf '\n'
  } > /usr/local/libexec/laplace-appdb-secrets-refresh
  chmod 755 /usr/local/libexec/laplace-appdb-secrets-refresh
  cat > /etc/systemd/system/laplace-appdb-secrets.service <<'UNIT'
[Unit]
Description=Refresh application database credentials from the host OpenBao AppRole
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/laplace-appdb-secrets-refresh
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
UNIT
  cat > /etc/systemd/system/laplace-appdb-secrets.timer <<'TIMER'
[Unit]
Description=Refresh application database credentials from OpenBao
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload
  systemctl enable --now laplace-appdb-secrets.timer
  say 'OpenBao appdb refresh' 'authentication verified; timer enabled; each invocation uses and revokes a scoped token'
}

database-client(){ part 'OpenBao substrate credentials'
  local host=${LAPLACE_BAO_DATABASE_HOST:-$(hostname -s)}
  local credentials=${LAPLACE_BAO_RUNTIME_CREDENTIALS:-${LAPLACE_BAO_CREDENTIALS:-/etc/laplace/approle.json}}
  local address=${BAO_ADDR:-https://openbao.hartonomous.com}
  local prefix=${LAPLACE_INSTALL_PREFIX:-/opt/laplace}
  local machine=${LAPLACE_MACHINE_ENV:-/etc/laplace/machine.env}
  local -a args=(--host "$host" --credentials "$credentials" --user "${LAPLACE_API_USER:-$LAPLACE_AGENT_USER}"
    --prefix "$prefix" --machine-file "$machine" --bao-address "$address"
    --lock "${LAPLACE_HOST_LOCK:-/run/lock/laplace/host-resource.lock}")
  if [[ -n ${LAPLACE_RUNTIME_DB_ROOT_CERTIFICATE:-} ]]; then
    args+=(--root-certificate "$LAPLACE_RUNTIME_DB_ROOT_CERTIFICATE")
  fi
  if [[ -n ${LAPLACE_BAO_APP_RUNTIME_RECORD:-} ]]; then
    args+=(--application-record "$LAPLACE_BAO_APP_RUNTIME_RECORD" --restart-on-change
      --verification-base "${LAPLACE_API_VERIFICATION_URL:-${LAPLACE_PUBLIC_BASE_URL:?API verification origin is required}}")
  fi
  python3 "$here/secrets/database-sync.py" "${args[@]}"
  # Credential verification precedes retirement of the previous refresh owner.
  if [[ $(systemctl show laplace-knowledge-refresh.timer -p LoadState --value) == loaded ]]; then
    systemctl disable --now laplace-knowledge-refresh.timer
    systemctl stop laplace-knowledge-refresh.service
  fi
  install -d -m 755 /usr/local/libexec
  install -m 755 "$here/secrets/database-sync.py" /usr/local/libexec/laplace-database-sync.py
  {
    printf '#!/bin/bash\nset -euo pipefail\nexec python3 /usr/local/libexec/laplace-database-sync.py '
    printf '%q ' "${args[@]}"
    printf '\n'
  } > /usr/local/libexec/laplace-database-refresh
  chmod 755 /usr/local/libexec/laplace-database-refresh
  cat > /etc/systemd/system/laplace-database-refresh.service <<'UNIT'
[Unit]
Description=Refresh Laplace substrate credential through OpenBao
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/laplace-database-refresh
NoNewPrivileges=true
UMask=0077
UNIT
  cat > /etc/systemd/system/laplace-database-refresh.timer <<'TIMER'
[Unit]
Description=Refresh Laplace substrate credentials every fifteen minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload
  systemctl enable --now laplace-database-refresh.timer
  say 'Substrate credential refresh' 'database authentication and native receipt verified; existing AppRole session revoked'
}

report(){ part report
  say "server" "$($PGBIN/postgres --version)   $(systemctl is-active "$SERVICE.service")"
  say "PostGIS" "$(q "SELECT default_version FROM pg_available_extensions WHERE name = 'postgis'")"
  say "listening" "$(ss -ltn | awk '$4 ~ /:5432$/ {print $4}' | tr '\n' ' ')"
  # this machine's address on $LAPLACE_LAN: the source the kernel would use towards that network (a /24 on a LAN
  # interface, a /10 tailnet on tailscale0: the prefix length does not matter)
  addr=$(ip -4 route get "$(echo "$LAPLACE_LAN" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."($4+1)}')" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  say "from the network, as $op" "$(as_op "$PGBIN/psql -X 'host=$addr port=5432 user=$LAPLACE_ROLE dbname=postgres sslmode=require' -Atc \"SELECT 'connected, TLS '||coalesce((SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'off')\"" 2>&1 | tail -1)"
  say "over the socket, as $op" "$(as_op "$PGBIN/psql -X 'host=/tmp port=5432 user=$LAPLACE_ROLE dbname=postgres' -Atc \"SELECT 'connected as '||current_user\"" 2>&1 | tail -1)"
  if [[ $setup_runtime_verified == 1 ]]; then
    say 'application runtime' 'API, MCP, database access and credential refresh verified; runtime receipt saved'
  else
    say 'installation scope' 'shared infrastructure and modular Laplace; monorepo setup belongs to Laplace/deploy/linux/site-host.sh'
  fi
}

setup_dispatch "$@"
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
