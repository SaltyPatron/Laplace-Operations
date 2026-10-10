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
    foreach ($line in Get-Content -LiteralPath $machineEnv) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $name = $Matches[1]; $value = $Matches[2]
            if ($value.Length -ge 2 -and $value[0] -in '"', "'" -and $value[-1] -eq $value[0]) { $value = $value.Substring(1, $value.Length - 2) }
            Set-Default $name ([Environment]::ExpandEnvironmentVariables($value))
        }
    }
}

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
Set-Default LAPLACE_LOCKS   "$env:LAPLACE_WORK\locks"                       # one deployment or ingest per database at a time: the locks
Set-Default LAPLACE_PGHOST  '127.0.0.1'                                     # where this machine's own tools reach the server: loopback (Windows has no socket)
Set-Default LAPLACE_PGPORT  '5432'                                          # the port the server listens on; the settings, the access rules and the firewall follow it
Set-Default LAPLACE_CONNINFO "host=$env:LAPLACE_PGHOST port=$env:LAPLACE_PGPORT user=$env:LAPLACE_ROLE dbname=laplace"   # libpq form; names the database. hart-server's: host=192.168.1.2 port=5432 user=laplace dbname=laplace sslmode=require
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

# The desktop's own parts (setup.ps1 shares, services, backup; none is part of all): the deployment target's shares
# this machine reaches by UNC path with a Credential Manager entry, the GPU services the operator starts and stops
# without elevation (chess\chess-gpu.ps1), and the copy-off of the drives to the deployment target (backup\).
Set-Default LAPLACE_SHARE_HOST   'hart-server'                              # setup.sh shares there serves them
Set-Default LAPLACE_SHARE_USER   'ahart'                                    # its SMB user: the Credential Manager entry's
Set-Default LAPLACE_SHARES       'vault,archive,backup,inbox'               # \\<host>\<share>, each checked
Set-Default LAPLACE_GPU_SERVICES 'llama-embedding,llama-embedding-text,llama-reranker,llama-generative'
Set-Default LAPLACE_FIREWALL     'engines=5190@192.168.1.2'                 # inbound rules, name=port@client;...: the engine endpoint for hart-server
Set-Default LAPLACE_BACKUP_TASK  'copyoff'                                  # the scheduled task that runs backup\run.ps1
Set-Default LAPLACE_BACKUP_LOGS  'D:\Logs\copyoff'                          # its logs, manifests, robocopy logs and patches
Set-Default LAPLACE_BACKUP_JOBS  "$PSScriptRoot\backup\jobs.psd1"           # what it copies, where to

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
Set-Default LAPLACE_UCD      "$env:LAPLACE_DATA\UCD"                        # the Unicode Character Database tier 0 is generated from
Set-Default LAPLACE_ICU_DIR  "$env:LAPLACE_DEPS\icu78"                      # ICU 78: Unicode 17, the version tier 0 is built from
Set-Default LAPLACE_BLAKE3_DIR "$env:LAPLACE_DEPSRC\blake3\c"
Set-Default LAPLACE_COREMATH   "$env:LAPLACE_DEPSRC\core-math"
Set-Default LAPLACE_TREESITTER "$env:LAPLACE_DEPSRC\tree-sitter"
Set-Default LAPLACE_MATH       "$env:LAPLACE_BUILD\..\laplace-math\icx-release\laplace-math.lib"
