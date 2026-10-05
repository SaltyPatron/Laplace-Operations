# Where everything is on the Windows machine: the counterpart of laplace.env (Reference: Environment). Every build,
# every script here and the laplace program read the same variables; one that is already set in the environment is
# kept, so another Windows machine sets its own before running setup.ps1. Dot-source it:
#   . "$PSScriptRoot\laplace.env.ps1"
# The compiler is the developer shell's (LAPLACE_DEVSHELL); this file sets no toolchain on the PATH.
function Set-Default([string]$name, [string]$value) { if (-not [Environment]::GetEnvironmentVariable($name)) { [Environment]::SetEnvironmentVariable($name, $value) } }

Set-Default LAPLACE_SRC     'D:\Repositories\Laplace'                       # Laplace's repositories
Set-Default LAPLACE_BUILD   'D:\Libraries\build\Laplace'                    # build trees
Set-Default LAPLACE_WORK    'D:\Data\Laplace\work'                          # generated data and logs
Set-Default LAPLACE_DEPSRC  'D:\Libraries\src'                              # the dependencies' sources (blake3, core-math, tree-sitter, ...)
Set-Default LAPLACE_DEPS    'D:\Libraries'                                  # installed dependencies
Set-Default LAPLACE_DATA    'D:\Data\Ingest'                                # corpora and the Unicode data

# The machine, as setup.ps1 declares it (Operations: Setup, Database). Every name here is this installation's choice.
Set-Default LAPLACE_PG_DIR  'D:\Libraries\postgresql\18.6'                  # PostgreSQL 18, built with icx (dependencies.tsv)
Set-Default LAPLACE_PGDATA  'D:\Data\Laplace\pgdata'                        # the cluster: heap and indexes
Set-Default LAPLACE_PGWAL   "$env:LAPLACE_PGDATA\pg_wal"                    # its write-ahead log; a path on another drive puts it there (initdb --waldir)
                                                                            # LAPLACE_PGTEMP, when set: its temporary files as the tablespace pgtemp, on another drive
Set-Default LAPLACE_PGSERVICE 'laplace-postgres'                            # the Windows service
Set-Default LAPLACE_PGUSER  'NT AUTHORITY\NetworkService'                   # the account the service runs as (S-1-5-20): owns the data and the logs, reads the install
Set-Default LAPLACE_ROLE    'laplace'                                       # the database role Laplace connects as
Set-Default LAPLACE_LAN     '192.168.1.0/24'                                # the network the server is reachable from; hart-server is on it
# The Windows identities this host authenticates as the role over loopback (SSPI, pg_ident map; setup.ps1 access): the
# counterpart of Linux's peer socket. The operator; IIS's pool for the monorepo's site (deploy\windows\Install-LaplaceSite.ps1:
# LaplacePool); the account the monorepo's managed services run as (scripts\win\ensure-managed-services.ps1: LocalService).
# Realm-stripped names, as SSPI presents them (include_realm=0).
Set-Default LAPLACE_PG_IDENTITIES "$env:USERNAME,LaplacePool,LOCAL SERVICE"
Set-Default LAPLACE_LOCKS   "$env:LAPLACE_WORK\locks"                       # one deployment or ingest per database at a time: the locks
Set-Default LAPLACE_CONNINFO "host=127.0.0.1 port=5432 user=$env:LAPLACE_ROLE dbname=laplace"   # libpq form; names the database. hart-server's: host=192.168.1.2 port=5432 user=laplace dbname=laplace sslmode=require
# The deployment target, whose operator holds the role's one password for the whole installation (setup.sh access writes
# it into every operator's ~/.pgpass there): this machine's role takes it, so one pgpass line reaches both databases
# and either machine is the other's client. Reached over the operator's SSH key. Unset: this machine makes its own.
Set-Default LAPLACE_PEER     'ahart@hart-server'
Set-Default LAPLACE_PEER_KEY "$env:USERPROFILE\.ssh\id_hartserver"

# The server's settings follow the machine (tune-pg.ps1): a quarter of the memory the server may use for the buffers,
# seven tenths of it for the cache estimate, the cores for the workers, half of a dedicated drive for the log. What a
# rule cannot read from the machine is declared here, each with the measurement that set it; another machine measures
# its own.
Set-Default LAPLACE_PG_RESERVED    '34GB'   # memory the machine's other residents keep: the three llama-server services commit about 34 of 48 GB (2026-10-05)
Set-Default LAPLACE_PG_BUFFERS_MAX '1GB'    # the largest shared memory this Windows build maps in every backend: at 4GB 826 backends in three hours could not (error 487); 1GB maps (2026-10-05)
Set-Default LAPLACE_PGWAL_ROOM     '32GB'   # the log's bound when it shares its drive (D: holds the heap, the sources and the models); a dedicated drive gets half of itself
Set-Default LAPLACE_PG_PRELOAD     'pg_stat_statements,auto_explain,laplace_substrate'   # the libraries the server loads at start: observability (tune-pg.sh), and the monorepo's substrate, which this server also serves (database laplace-mono)
Set-Default LAPLACE_PG_LIBDIRS     'D:\Data\Laplace\deploy\lib'   # where the monorepo installs its extension DLLs (scripts\win\install-extensions.cmd); a preload library is declared only once its DLL is there

# The toolchain: the developer shell (Visual Studio's vcvars64, oneAPI, CMake, the manifest's build tools) and the
# MSYS2 that builds PostGIS (toolchain\windows\postgis.sh).
Set-Default LAPLACE_DEVSHELL 'D:\Libraries\load-env.ps1'
Set-Default LAPLACE_MSYS2    'D:\Libraries\msys64'

Set-Default LAPLACE_NATIVE   "$env:LAPLACE_SRC\Laplace-Native"
Set-Default LAPLACE_OPERATIONS "$env:LAPLACE_SRC\Laplace-Operations"
Set-Default LAPLACE_RECIPES  "$env:LAPLACE_SRC\Laplace-Engine\recipes"
Set-Default LAPLACE_FIRMWARE "$env:LAPLACE_SRC\Laplace-Engine\firmware\program.firmware"   # the firmware a pull runs under
Set-Default LAPLACE_TIER0    "$env:LAPLACE_WORK\tier0\tier0.bin"            # laplace tier0 writes it; every install with its fingerprint agrees
Set-Default LAPLACE_HIGHWAY  "$env:LAPLACE_WORK\tier0\tier0.highway"        # laplace highway writes it
Set-Default LAPLACE_GRAMMARS "$env:LAPLACE_BUILD\grammars"                  # the tree-sitter grammars, built once
Set-Default LAPLACE_UCD      'D:\Data\UCD'                                  # the Unicode Character Database tier 0 is generated from
Set-Default LAPLACE_ICU_DIR  "$env:LAPLACE_DEPS\icu78"                      # ICU 78: Unicode 17, the version tier 0 is built from
Set-Default LAPLACE_BLAKE3_DIR "$env:LAPLACE_DEPSRC\blake3\c"
Set-Default LAPLACE_COREMATH   "$env:LAPLACE_DEPSRC\core-math"
Set-Default LAPLACE_TREESITTER "$env:LAPLACE_DEPSRC\tree-sitter"
Set-Default LAPLACE_ZLIB_DIR    "$env:LAPLACE_DEPS\zlib\1.3.2"              # Laplace-Engine on Windows: zlib's import library and headers (dependencies.tsv)
Set-Default LAPLACE_EIGEN_DIR   "$env:LAPLACE_DEPSRC\eigen"                 # Laplace-Native's laplace_linalg: the checkouts at the manifest's pins
Set-Default LAPLACE_SPECTRA_DIR "$env:LAPLACE_DEPSRC\spectra"
Set-Default LAPLACE_MATH       "$env:LAPLACE_BUILD\..\laplace-math\icx-release\laplace-math.lib"   # setup.ps1 deps builds it first (math\CMakeLists.txt)

# What the engine reads is '/'-separated on every platform (Laplace-Engine src/os.h): its paths, whatever a shell wrote
foreach ($n in 'LAPLACE_DATA', 'LAPLACE_WORK', 'LAPLACE_TIER0', 'LAPLACE_HIGHWAY', 'LAPLACE_RECIPES', 'LAPLACE_FIRMWARE', 'LAPLACE_GRAMMARS', 'LAPLACE_UCD', 'LAPLACE_NATIVE') {
    $v = [Environment]::GetEnvironmentVariable($n); if ($v) { [Environment]::SetEnvironmentVariable($n, ($v -replace '\\', '/')) }
}

# The engine's run-time libraries, on the PATH once (Toolchain 2.7: the one environment file sources oneAPI): MKL and
# OpenMP from oneAPI's redistributable directories, libpq beside the server, ICU, zlib, and the engine itself.
Set-Default LAPLACE_ONEAPI 'C:\Program Files (x86)\Intel\oneAPI'
foreach ($d in @("$env:LAPLACE_BUILD\Laplace-Engine\icx-release", "$env:LAPLACE_PG_DIR\bin", "$env:LAPLACE_ICU_DIR\bin64", "$env:LAPLACE_ZLIB_DIR\bin", "$env:LAPLACE_ONEAPI\mkl\latest\bin", "$env:LAPLACE_ONEAPI\compiler\latest\bin")) {
    if ((Test-Path $d) -and (($env:PATH -split ';') -notcontains $d)) { $env:PATH = "$d;$env:PATH" }
}
