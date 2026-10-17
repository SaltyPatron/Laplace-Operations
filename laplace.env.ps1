# Where everything is on the Windows machine: the counterpart of laplace.env (Reference: Environment). Every build,
# every script here and the laplace program read the same variables; one that is already set in the environment is
# kept, so another Windows machine sets its own before running setup.ps1. Dot-source it:
#   . "$PSScriptRoot\laplace.env.ps1"
# The compiler is the developer shell's (LAPLACE_DEVSHELL); this file sets no toolchain on the PATH.
function Set-Default([string]$name, [string]$value) { if (-not [Environment]::GetEnvironmentVariable($name)) { [Environment]::SetEnvironmentVariable($name, $value) } }

# Another machine declares what differs from HART-DESKTOP in %ProgramData%\Laplace\machine.env (LAPLACE_MACHINE_ENV
# names another file): the counterpart of /etc/laplace/machine.env and the same format, one NAME=value per line, # for
# a comment, %NAME% expanded. It is read first, so every tool and service on the machine sees one declaration without
# anyone's shell environment; a value set in the environment still wins.
$machineEnv = if ($env:LAPLACE_MACHINE_ENV) { $env:LAPLACE_MACHINE_ENV } else { Join-Path $env:ProgramData 'Laplace\machine.env' }
if (Test-Path -LiteralPath $machineEnv) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $machineEnv) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $name = $Matches[1]; $value = $Matches[2]
            if (-not $seen.Add($name)) { throw "Duplicate configuration key: $name" }
            if ($value.Length -ge 2 -and $value[0] -in '"', "'" -and $value[-1] -eq $value[0]) { $value = $value.Substring(1, $value.Length - 2) }
            if ($value -match '["\r\n]') { throw "Unsupported quote or newline in configuration key: $name" }
            Set-Default $name ([Environment]::ExpandEnvironmentVariables($value))
        } else { throw "Invalid configuration line in $machineEnv" }
    }
    $env:LAPLACE_CONFIG_SOURCE = [IO.Path]::GetFullPath($machineEnv)
} elseif ($env:LAPLACE_MACHINE_ENV) { throw "LAPLACE_MACHINE_ENV does not name a file: $machineEnv" }
else { $env:LAPLACE_CONFIG_SOURCE = 'defaults' }

Set-Default LAPLACE_DATA_ROOT (Join-Path $env:LOCALAPPDATA 'Laplace')
Set-Default LAPLACE_SRC     (Join-Path $env:USERPROFILE 'source\repos')
Set-Default LAPLACE_WORK    "$env:LAPLACE_DATA_ROOT\work"
Set-Default LAPLACE_BUILD   "$env:LAPLACE_WORK\build"
$checkout = if ($env:LAPLACE_ROOT) { $env:LAPLACE_ROOT } else { [IO.Path]::Combine($env:LAPLACE_SRC, 'Laplace') }
$checkout = [IO.Path]::GetFullPath($checkout).TrimEnd('\').ToLowerInvariant()
$workspaceId = [IO.Path]::GetFileName($checkout) + '-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($checkout))).Substring(0,12).ToLowerInvariant()
Set-Default LAPLACE_BUILD_ROOT "$env:LAPLACE_BUILD\worktrees\$workspaceId"
Set-Default LAPLACE_ENGINE_BUILD "$env:LAPLACE_BUILD_ROOT\build-win"
Set-Default LAPLACE_DEPS    "$env:LAPLACE_DATA_ROOT\dependencies"
Set-Default LAPLACE_DEPSRC  "$env:LAPLACE_DEPS\src"
Set-Default LAPLACE_EXTERNAL $env:LAPLACE_DEPSRC
Set-Default LAPLACE_DATA    "$env:LAPLACE_DATA_ROOT\data"
Set-Default LAPLACE_MODELS  "$env:LAPLACE_DATA_ROOT\models"                 # model files the recipes read (Laplace-Engine recipes/tokenizers)

# The machine, as setup.ps1 declares it (Operations: Setup, Database). Every name here is this installation's choice.
Set-Default LAPLACE_PG_DIR  (Join-Path "$env:LAPLACE_DEPS\postgresql" ((Get-Content "$PSScriptRoot\dependencies.tsv" | Where-Object { $_ -match '^postgresql\t' } | Select-Object -First 1) -split "`t")[1])
Set-Default LAPLACE_PGDATA  "$env:LAPLACE_DATA_ROOT\pgdata"
Set-Default LAPLACE_PGWAL   "$env:LAPLACE_PGDATA\pg_wal"                    # its write-ahead log; a path on another drive puts it there (initdb --waldir)
                                                                            # LAPLACE_PGTEMP, when set: its temporary files as the tablespace pgtemp, on another drive
Set-Default LAPLACE_PG_WAL_DEDICATED '0'                                   # 1 only when the separate WAL drive holds no other workloads; a different drive alone is not dedicated
Set-Default LAPLACE_PGSERVICE 'laplace-postgres'                            # the Windows service
Set-Default LAPLACE_PG_SERVICE_ACCOUNT 'NT AUTHORITY\NetworkService'       # Windows service identity; never a database login
Set-Default LAPLACE_ROLE    'laplace'                                       # the database role Laplace connects as
Set-Default LAPLACE_PGUSER   $env:LAPLACE_ROLE
Set-Default LAPLACE_LAN     '127.0.0.1/32'                                # remote database access requires the host's declared network
# The Windows identities this host authenticates as the role over loopback (SSPI, pg_ident map; setup.ps1 access): the
# counterpart of Linux's peer socket. The operator; IIS's pool for the monorepo's site (deploy\windows\Install-LaplaceSite.ps1:
# LaplacePool); the account the monorepo's managed services run as (scripts\win\ensure-managed-services.ps1: LocalService).
# Realm-stripped names, as SSPI presents them (include_realm=0).
Set-Default LAPLACE_PG_IDENTITIES "$env:USERNAME,LaplacePool,LOCAL SERVICE"
Set-Default LAPLACE_LOCKS   "$env:LAPLACE_WORK\locks"                       # one deployment or ingest per database at a time: the locks
Set-Default LAPLACE_PGHOST  '127.0.0.1'                                     # where this machine's own tools reach the server: loopback (Windows has no socket)
Set-Default LAPLACE_PGPORT  '5432'                                          # the port the server listens on; the settings, the access rules and the firewall follow it
Set-Default LAPLACE_PG_LISTEN_ADDRESSES '*'                                # includes interfaces appearing after service startup; pg_hba owns admission
Set-Default LAPLACE_CONNINFO "host=$env:LAPLACE_PGHOST port=$env:LAPLACE_PGPORT user=$env:LAPLACE_ROLE dbname=laplace"   # libpq form; names the database. hart-server's: host=192.168.1.2 port=5432 user=laplace dbname=laplace sslmode=require
# The deployment target, whose operator holds the role's one password for the whole installation (setup.sh access writes
# it into every operator's ~/.pgpass there): this machine's role takes it, so one pgpass line reaches both databases
# and either machine is the other's client. Reached over the operator's SSH key. Unset: this machine makes its own.
# LAPLACE_PEER and LAPLACE_PEER_KEY are optional host declarations.

# The server's settings follow the machine (tune-pg.ps1): a quarter of the memory the server may use for the buffers,
# seven tenths of it for the cache estimate, the cores for the workers, half of a dedicated drive for the log. What a
# rule cannot read from the machine is declared here, each with the measurement that set it; another machine measures
# its own.
Set-Default LAPLACE_PGWAL_ROOM     '32GB'   # the log's bound when it shares its drive (D: holds the heap, the sources and the models); a dedicated drive gets half of itself
Set-Default LAPLACE_PG_PRELOAD     'pg_stat_statements,auto_explain,laplace_substrate'   # the libraries the server loads at start: observability (tune-pg.sh), and the monorepo's substrate, which this server also serves (database laplace-mono)
Set-Default LAPLACE_PG_LIBDIRS     "$env:LAPLACE_DATA_ROOT\deploy\lib"
# What an ingest decomposes at once (laplace ingest: LAPLACE_BATCH_MB, 1024 unless set): the batch's node table lives in
# memory, and an XML source spends far more memory than its bytes. This machine has 13 GB left after the llama
# services' 34 GB; FrameNet's 849 MB as one batch ran out of it (realloc: Not enough space, 2026-10-05). 256 MB fits.
Set-Default LAPLACE_BATCH_MB       '256'

# The desktop's own parts (setup.ps1 shares, services, backup; none is part of all): the deployment target's shares
# this machine reaches by UNC path with a Credential Manager entry, the GPU services the operator starts and stops
# without elevation (chess\chess-gpu.ps1), and the copy-off of the drives to the deployment target (backup\).
# LAPLACE_SHARE_HOST is an explicit host declaration when SMB is used.
Set-Default LAPLACE_SHARE_USER   $env:USERNAME
Set-Default LAPLACE_SHARES       'vault,archive,backup,inbox'               # \\<host>\<share>, each checked
Set-Default LAPLACE_GPU_SERVICES 'llama-embedding,llama-embedding-text,llama-reranker,llama-generative'
# LAPLACE_FIREWALL is opt-in: name=port@client;... for this host's actual clients.
Set-Default LAPLACE_BACKUP_TASK  'copyoff'                                  # the scheduled task that runs backup\run.ps1
Set-Default LAPLACE_BACKUP_LOGS  "$env:LAPLACE_WORK\logs\backup"            # follows the machine's declared work volume
Set-Default LAPLACE_BACKUP_JOBS  "$PSScriptRoot\backup\jobs.psd1"           # what it copies, where to

# The toolchain: the developer shell (Visual Studio's vcvars64, oneAPI, CMake, the manifest's build tools) and the
# MSYS2 that builds PostGIS (toolchain\windows\postgis.sh).
Set-Default LAPLACE_DEVSHELL "$PSScriptRoot\toolchain\windows\devshell.ps1"   # finds them on the machine; never written by hand
# LAPLACE_MSYS2: an MSYS2 the machine already has. Unset, it is where setup.ps1 deps unpacks the manifest's msys2 row.
# A row of the manifest is installed at <deps>\<name>\<its version> (setup.ps1 deps): the version is said once, there.
function DepPrefix([string]$name) { Join-Path "$env:LAPLACE_DEPS\$name" ((Get-Content "$PSScriptRoot\dependencies.tsv" | Where-Object { $_ -match "^$([regex]::Escape($name))`t" } | Select-Object -First 1) -split "`t")[1] }

Set-Default LAPLACE_NATIVE   "$env:LAPLACE_SRC\Laplace-Native"
Set-Default LAPLACE_OPERATIONS "$env:LAPLACE_SRC\Laplace-Operations"
Set-Default LAPLACE_RECIPES  "$env:LAPLACE_SRC\Laplace-Engine\recipes"
Set-Default LAPLACE_FIRMWARE "$env:LAPLACE_SRC\Laplace-Engine\firmware\program.firmware"   # the firmware a pull runs under
Set-Default LAPLACE_TIER0    "$env:LAPLACE_WORK\tier0\tier0.bin"            # laplace tier0 writes it; every install with its fingerprint agrees
Set-Default LAPLACE_HIGHWAY  "$env:LAPLACE_WORK\tier0\tier0.highway"        # laplace highway writes it
Set-Default LAPLACE_GRAMMARS "$env:LAPLACE_BUILD\grammars"                  # the tree-sitter grammars, built once
Set-Default LAPLACE_UCD      "$env:LAPLACE_DATA\UCD"                        # the Unicode Character Database tier 0 is generated from
Set-Default LAPLACE_ICU_DIR  (DepPrefix 'icu')                             # ICU 78: Unicode 17, the version tier 0 is built from
Set-Default LAPLACE_BLAKE3_DIR "$env:LAPLACE_DEPSRC\blake3\c"
Set-Default LAPLACE_COREMATH   "$env:LAPLACE_DEPSRC\core-math"
Set-Default LAPLACE_TREESITTER "$env:LAPLACE_DEPSRC\tree-sitter"
Set-Default LAPLACE_ZLIB_DIR    (DepPrefix 'zlib')                          # Laplace-Engine on Windows: zlib's import library and headers (dependencies.tsv)
Set-Default LAPLACE_EIGEN_DIR   "$env:LAPLACE_DEPSRC\eigen"                 # Laplace-Native's laplace_linalg: the checkouts at the manifest's pins
Set-Default LAPLACE_SPECTRA_DIR "$env:LAPLACE_DEPSRC\spectra"
Set-Default LAPLACE_MATH       "$env:LAPLACE_BUILD\..\laplace-math\icx-release\laplace-math.lib"   # setup.ps1 deps builds it first (math\CMakeLists.txt)

# What the engine reads is '/'-separated on every platform (Laplace-Engine src/os.h): its paths, whatever a shell wrote
foreach ($n in 'LAPLACE_DATA', 'LAPLACE_MODELS', 'LAPLACE_WORK', 'LAPLACE_TIER0', 'LAPLACE_HIGHWAY', 'LAPLACE_RECIPES', 'LAPLACE_FIRMWARE', 'LAPLACE_GRAMMARS', 'LAPLACE_UCD', 'LAPLACE_NATIVE') {
    $v = [Environment]::GetEnvironmentVariable($n); if ($v) { [Environment]::SetEnvironmentVariable($n, ($v -replace '\\', '/')) }
}

# The engine's run-time libraries, on the PATH once (Toolchain 2.7: the one environment file sources oneAPI): MKL and
# OpenMP from oneAPI's redistributable directories, libpq beside the server, ICU, zlib, and the engine itself.
# oneAPI is where its installer put it: ONEAPI_ROOT when it set one, else above the compiler it registered for the
# machine (IFORT_COMPILER<yy> or ICPP_COMPILER<yy>: <oneAPI>\compiler\<version>\), the newest. Its unified layout keeps
# every run-time library in <oneAPI>\<version>\bin; the component layout in mkl\latest\bin and compiler\latest\bin.
if (-not $env:LAPLACE_ONEAPI) {
    $env:LAPLACE_ONEAPI = $env:ONEAPI_ROOT
    if (-not $env:LAPLACE_ONEAPI) {
        $reg = [Environment]::GetEnvironmentVariables('Machine')
        $d = $reg.Keys | Where-Object { $_ -match '^(IFORT|ICPP)_COMPILER\d+$' } | Sort-Object { [int]($_ -replace '\D') } | Select-Object -Last 1 | ForEach-Object { ([string]$reg[$_]).TrimEnd('\') }
        while ($d -and -not $env:LAPLACE_ONEAPI) { if (Test-Path (Join-Path $d 'setvars.bat')) { $env:LAPLACE_ONEAPI = $d } else { $d = Split-Path $d } }
    }
}
$oneapiBin = if ($env:LAPLACE_ONEAPI) { Get-ChildItem -LiteralPath $env:LAPLACE_ONEAPI -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' -and (Test-Path (Join-Path $_.FullName 'bin\libmmd.dll')) } | Sort-Object { [version]$_.Name } | Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName 'bin' } }
foreach ($d in @("$env:LAPLACE_BUILD\Laplace-Engine\icx-release", "$env:LAPLACE_PG_DIR\bin", "$env:LAPLACE_ICU_DIR\bin64", "$env:LAPLACE_ZLIB_DIR\bin", "$env:LAPLACE_ONEAPI\mkl\latest\bin", "$env:LAPLACE_ONEAPI\compiler\latest\bin", $oneapiBin)) {
    if (-not $d) { continue }
    if ((Test-Path $d) -and (($env:PATH -split ';') -notcontains $d)) { $env:PATH = "$d;$env:PATH" }
}
