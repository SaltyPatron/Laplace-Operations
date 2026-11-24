#Requires -Version 7
<#
  The Windows machine Laplace is developed on, declared once and converged: the counterpart of setup.sh (Operations:
  Setup, Database). The same parts, in the same order; each compares its declaration with the machine and makes only
  what is missing, so running it again on a finished machine changes nothing and reports. What it did is kept under
  $LAPLACE_WORK\logs\root. Every name of this machine's is a variable of laplace.env.ps1, so another Windows machine
  declares its own.

    pwsh -File setup.ps1                   development inputs and manifest for the declared desktop checkout
    pwsh -File setup.ps1 all               explicitly install the local PostgreSQL development server as well
    pwsh -File setup.ps1 deps report       one part, or several: volumes | packages | rights | deps | cluster | settings | access | report
    $env:LAPLACE_DROP = 'D:\Data\Laplace\pgdata'; pwsh -File setup.ps1 drop all
                                           the cluster dropped and made again, empty: never part of all, and named to be dropped
    pwsh -File setup.ps1 shares            the desktop's own parts, never part of all: shares (the deployment target's
    pwsh -File setup.ps1 services          shares answer by UNC path, with a credential), services (the operator starts and
    pwsh -File setup.ps1 firewall          stops the GPU services; elevated), firewall (the inbound rules of
    pwsh -File setup.ps1 backup            LAPLACE_FIREWALL; elevated), backup (the copy-off task, backup\)
    pwsh -File setup.ps1 backup status     status with any of them (alone: all four) reports and changes nothing

  What differs from Linux is only what Windows forces: a drive is not made here (no volumes to create, so volumes
  reports the drives and makes the directories); the toolchain is installed by hand or by the manifest (packages says
  what is missing and installs MSYS2's packages); there is no kernel part (huge pages: tune-pg.ps1); the service is a
  Windows service under NT AUTHORITY\NetworkService; there is no socket, so every local connection is scram on
  loopback. This machine is one leg of the cross-OS check: a database Linux clients reach over the LAN with TLS, and a
  client of hart-server's database (LAPLACE_CONNINFO), and report tries both.

  Policy (Laplace-Operations#2): a service never reads a person's environment; no toolchain on the global PATH (the
  developer shell is LAPLACE_DEVSHELL); privileged steps happen here and only here. HART-DESKTOP's one-time cleanup
  of what earlier set-ups left is toolchain\windows\retire.ps1, not this.
#>
param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Parts = @('development'), [switch]$Check, [string]$Installation)
$ErrorActionPreference = 'Stop'
function Install-LaplaceOpsCommand {
    $bin = Join-Path $env:LOCALAPPDATA 'Laplace\bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $opsCmd = Join-Path $bin 'laplace-ops.cmd'
    $opsPs1 = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'laplace.ps1'))
    $pwshExe = (Get-Command pwsh).Source
    Set-Content -LiteralPath $opsCmd -Value "@echo off`r`nsetlocal DisableDelayedExpansion`r`n`"$pwshExe`" -NoLogo -NoProfile -File `"$opsPs1`" %*`r`nexit /b %errorlevel%`r`n" -NoNewline
    $userPath = [string][Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($bin -notin @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('PATH', (($userPath.TrimEnd(';') + ';' + $bin).TrimStart(';')), 'User')
    }
    if ($bin -notin @($env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\') })) {
        $env:PATH = "$bin;$env:PATH"
    }
    Write-Host "Registered laplace-ops CLI: $opsCmd (run 'laplace-ops' for help)"
}
if ($Parts.Count -eq 1 -and $Parts[0] -in @('help','-h','--help','/?')) {
    @'
Laplace Windows Host Setup (setup.ps1)

USAGE
  pwsh -File setup.ps1                  Prepare dev inputs (UCD, grammars, dependency manifest) and install 'laplace-ops' CLI on PATH
  pwsh -File setup.ps1 all              Full elevated Windows host setup: volumes, packages, rights, deps, postgres, cluster, settings, access, report
  pwsh -File setup.ps1 <part...>        Run specific setup stages:
                                          volumes | packages | rights | deps | postgres | cluster | settings | access | report
                                          network | shares | services | firewall | backup | status
  pwsh -File setup.ps1 client           Package Laplace-Native + Laplace-Engine and install the modular 'laplace' CLI
  pwsh -File setup.ps1 clean            Clean unused local releases, packages and abandoned generated output
  pwsh -File setup.ps1 tree-sitter      Build and verify the pinned grammar generator and its isolated Rust SDK
  pwsh -File setup.ps1 repair-postgres  Repair codec DLLs and service startup; verify the original cluster (no database reset)
  pwsh -File setup.ps1 repair-postgres -Check  Inspect the selected service and required repair without changing it
  pwsh -File setup.ps1 secrets-agents   Configure or check OpenBao secrets agents

Once setup.ps1 has been run once, use 'laplace-ops' from any directory for daily builds, database maintenance, IIS, and deployments.
'@ | Write-Host
    return
}
if ($Parts.Count -eq 1 -and $Parts[0] -in @('clean','cleanup')) {
    $cleanupOperation=if($Check){'storage'}else{'clean'}
    & "$PSScriptRoot/laplace.ps1" $cleanupOperation -Installation $Installation
    return
}
if ($Parts.Count -eq 1 -and $Parts[0] -eq 'secrets-agents') {
    if (-not $Installation) { $Installation = Join-Path $PSScriptRoot ('installation/'+$env:COMPUTERNAME.ToLowerInvariant()+'-secrets-agents.json') }
    & "$PSScriptRoot/secrets/upgrade-agents.ps1" -Installation $Installation -Check:$Check
    return
}
if ($Parts.Count -eq 1 -and $Parts[0] -eq 'client') {
    if ($Check) { throw 'Client installation does not accept -Check; inspect an installed client with laplace --where and laplace status.' }
    if (-not $Installation) {
        $hostManifest = Join-Path $PSScriptRoot ('installation/' + $env:COMPUTERNAME.ToLowerInvariant() + '-modular-client.json')
        if (Test-Path -LiteralPath $hostManifest) { $Installation = $hostManifest }
        else { throw 'Pass -Installation with the modular client declaration.' }
    }
    & "$PSScriptRoot/installation/install-windows-client.ps1" -Installation $Installation
    return
}
if ($Parts.Count -eq 1 -and $Parts[0] -eq 'postgres') {
    & "$PSScriptRoot/installation/postgres-installation.ps1" -Check:$Check
    return
}
if ($Parts.Count -eq 1 -and $Parts[0] -eq 'tree-sitter') {
    & "$PSScriptRoot/installation/build-tree-sitter.ps1" -Check:$Check
    return
}
if ($Check -and -not ($Parts.Count -eq 1 -and $Parts[0] -eq 'repair-postgres')) { throw '-Check applies to postgres, tree-sitter and repair-postgres.' }
if ($Parts -contains 'development') {
    if ($Parts.Count -ne 1) { throw 'Run the development profile separately from explicit database/service installation steps.' }
    Install-LaplaceOpsCommand
    . "$PSScriptRoot/laplace.env.ps1"
    . "$PSScriptRoot/installation/storage.ps1"
    $storageOperation=Enter-DesktopStorageOperation
    try {
        & pwsh -NoProfile -File "$PSScriptRoot/dev.ps1" -Operation prepare
        $developmentExitCode=$LASTEXITCODE
    }finally{Exit-DesktopStorageOperation $storageOperation}
    exit $developmentExitCode
}
$ReadOnlyPgRepair = [bool]$Check
. "$PSScriptRoot\laplace.env.ps1"
. "$PSScriptRoot\tune-pg.ps1"

$Src = $env:LAPLACE_SRC; $Build = $env:LAPLACE_BUILD; $Work = $env:LAPLACE_WORK; $DepSrc = $env:LAPLACE_DEPSRC; $Deps = $env:LAPLACE_DEPS; $Data = $env:LAPLACE_DATA
$PgDir = $env:LAPLACE_PG_DIR; $PgBin = Join-Path $PgDir 'bin'; $PgData = $env:LAPLACE_PGDATA; $PgWal = $env:LAPLACE_PGWAL; $PgTemp = $env:LAPLACE_PGTEMP
$PgHost = $env:LAPLACE_PGHOST; $PgPort = $env:LAPLACE_PGPORT; $PgService = $env:LAPLACE_PGSERVICE; $PgAccount = $env:LAPLACE_PG_SERVICE_ACCOUNT; $PgRole = $env:LAPLACE_ROLE; $PgLan = $env:LAPLACE_LAN; $Locks = $env:LAPLACE_LOCKS
$PgLogs = Join-Path $Work 'logs\postgres'
$PgCanon = Join-Path $env:ProgramData 'Laplace\pgpass.conf'
$Math = $env:LAPLACE_MATH; $DevShell = $env:LAPLACE_DEVSHELL
$Toolchain = Join-Path $PSScriptRoot 'toolchain\laplace.cmake'

$logDir = Join-Path $Work 'logs\root'
$log = Join-Path $logDir ("setup-{0:yyyyMMddTHHmmssZ}.log" -f (Get-Date).ToUniversalTime())
if (-not $ReadOnlyPgRepair) {
    New-Item -ItemType Directory -Force $logDir | Out-Null
    Start-Transcript -Path $log | Out-Null
}
$failed = [System.Collections.Generic.List[string]]::new()

# ------------------------------------------------------------------------------------------------------ the sets
# The toolchain the builds need, each known by its program: installed by hand (Visual Studio, oneAPI: the developer
# shell), by the manifest (perl, win_bison, win_flex, nasm: deps), or as a uv tool (meson).
$Tools = [ordered]@{
    icx = 'oneAPI, in the developer shell'; cmake = 'CMake 3.25 or newer (Kitware, standalone)'; ninja = 'Ninja'; git = 'Git for Windows'
    uv = 'uv (Python Install Manager)'; meson = 'uv tool install meson (dependencies.tsv)'; perl = 'Strawberry Perl (dependencies.tsv, in the developer shell)'
    win_bison = 'winflexbison (dependencies.tsv, in the developer shell)'; nasm = 'NASM (dependencies.tsv, in the developer shell)'
}
# MSYS2's packages: what toolchain\windows\postgis.sh runs under (autotools, make, pkgconf; MinGW's cpp for the SQL).
$Msys2Packages = 'autoconf', 'automake', 'libtool', 'make', 'pkgconf', 'bison', 'flex', 'mingw-w64-ucrt-x86_64-gcc'   # bison, flex: a checkout of PostGIS carries its grammars, not the parsers made from them
# How each dependency the manifest says to build is configured on Windows: the options beyond the toolchain file,
# the contract and the prefix, as the installs on HART-DESKTOP were made (their build trees' caches, 2026-10-04).
$DepSourceDir = @{ lz4 = 'build\cmake'; zstd = 'build\cmake' }
$DepOptions = @{
    # ICX 2026.1 loop vectorization leaves bytes unwritten in the LZ4 decoder.
    # Keep /O2 and SLP; tests/windows-lz4.ps1 reproduces the installed failure.
    lz4       = @('-DLZ4_BUILD_CLI=OFF', '-DBUILD_STATIC_LIBS=OFF', '-DCMAKE_C_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /clang:-fno-vectorize')
    # The same optimizer also corrupts overlapping Zstd matches during WAL recovery.
    # tests/windows-zstd.ps1 checks the actual installed DLL with synthetic data.
    zstd      = @('-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF', '-DZSTD_BUILD_CONTRIB=OFF', '-DCMAKE_C_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /clang:-fno-vectorize')
    libxml2   = @('-DLIBXML2_WITH_PROGRAMS=OFF', '-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_ICONV=OFF', '-DLIBXML2_WITH_HTTP=OFF')
    'json-c'  = @('-DBUILD_APPS=OFF')
    libtiff   = @("-DCMath_LIBRARY=$Math")   # its required CMath (libm) is laplace-math itself: Intel's libm, found otherwise, collides with it on atan2/exp/log/pow
    curl      = @('-DBUILD_CURL_EXE=OFF', '-DCURL_USE_SCHANNEL=ON', '-DCURL_USE_LIBPSL=OFF')   # TLS from Windows, not OpenSSL: PROJ fetches grids
    'win-iconv' = @('-DWIN_ICONV_BUILD_TEST=OFF')
}
# Header-only rows: what is copied from the checkout into the prefix.
$DepHeaders = @{ eigen = @(@{ From = 'Eigen'; To = 'include\eigen3\Eigen' }, @{ From = 'unsupported'; To = 'include\eigen3\unsupported' }); spectra = @(@{ From = 'include\Spectra'; To = 'include\Spectra' }) }
# SQLite's amalgamation: one C file, compiled as a DLL with what PROJ needs (dependencies.tsv).
$SqliteDefines = '/DSQLITE_ENABLE_RTREE', '/DSQLITE_ENABLE_COLUMN_METADATA', '/DSQLITE_ENABLE_FTS5', '/DSQLITE_ENABLE_MATH_FUNCTIONS', '/DSQLITE_ENABLE_JSON1'
# PostgreSQL's Meson options (the libraries from the manifest's depends; the contract from the native file).
$PgMesonOptions = '-Dbuildtype=release', '-Dicu=enabled', '-Dssl=openssl', '-Dzlib=enabled', '-Dlz4=enabled', '-Dzstd=enabled', '-Dlibxml=enabled',
                  '-Dnls=disabled', '-Dplperl=disabled', '-Dplpython=disabled', '-Dtap_tests=disabled', '-Dllvm=disabled'

# ------------------------------------------------------------------------------------------------------ helpers
function Say([string]$what, [string]$state) { '  {0,-58} {1}' -f $what, $state }
function Part([string]$name) { ''; "=== $name   {0:HH:mm:ss}" -f (Get-Date).ToUniversalTime() }
function Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Elevated([string]$part) { if (Admin) { return $true }; Say $part 'REFUSED: run from an elevated PowerShell'; $failed.Add("${part}: not elevated"); $false }
function Attempt([string]$what, [scriptblock]$body) {
    try { & $body } catch { Say $what "FAILED: $($_.Exception.Message)"; $failed.Add("$what : $($_.Exception.Message)") }
}
function Exec([string]$exe, [string[]]$arguments) {   # a build step: its output into the log, a failure thrown
    & $exe @arguments 2>&1 | ForEach-Object { "    $_" }
    if ($LASTEXITCODE) { throw "$([IO.Path]::GetFileName($exe)) $($arguments[0]) exited $LASTEXITCODE" }
}
function DriveOf([string]$path) { ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path))).Substring(0, 1).ToUpperInvariant() }
function MsysPath([string]$path) { '/' + ($path.Substring(0, 1).ToLowerInvariant()) + ($path.Substring(2) -replace '\\', '/') }
function GitIn([string]$dir) { & git.exe -C $dir @args 2>&1 }   # not named Git: a function would shadow git.exe
# the developer shell, once, when icx is not already on the PATH: Visual Studio's vcvars64, oneAPI, CMake, the tools
function DevShell {
    # icx alone on the PATH is not the developer shell (laplace.env.ps1 puts oneAPI's bin there for the engine's run-time
    # DLLs): the MSVC environment, which vcvars marks with VSCMD_VER, is what a build needs
    if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue))) {
        if (-not (Test-Path $DevShell)) { return $false }
        . $DevShell *> $null
    }
    # the manifest's build tools first on the PATH, ahead of any same-named program the shell brought (Git's perl, whose
    # modules are Unix's, configured OpenSSL and generated PostgreSQL's headers wrongly)
    foreach ($t in @(Manifest | Where-Object { $_.kind -eq 'tool' -and $_.build -eq 'unpack' })) {
        $p = Prefix $t; if ($t.name -eq 'strawberry-perl') { $p = Join-Path $p 'perl\bin' }
        if ((Test-Path $p) -and (($env:PATH -split ';') -notcontains $p)) { $env:PATH = "$p;$env:PATH" }
    }
    [bool](Get-Command icx.exe -ErrorAction SilentlyContinue)
}
function PgReady { & "$PgBin\pg_isready.exe" -h $PgHost -p $PgPort 2>$null | Out-Null; $LASTEXITCODE -eq 0 }
# one statement to the server, as a superuser: postgres (trust on a cluster initdb made; its declared password after
# access), else the role with the canonical password
function PgSql([string]$sql) {
    $previousPassword = $env:PGPASSWORD; $previousPassfile = $env:PGPASSFILE
    try {
        $out = & "$PgBin\psql.exe" -X -w -h $PgHost -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq -c $sql 2>&1
        if (-not $LASTEXITCODE) { return $out }
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue; $env:PGPASSFILE = $PgCanon
        $out = & "$PgBin\psql.exe" -X -w -h $PgHost -p $PgPort -U $PgRole -d postgres -v ON_ERROR_STOP=1 -Atq -c $sql 2>&1
        if ($LASTEXITCODE) { throw "psql: $($out -join ' ')" }
        $out
    } finally { $env:PGPASSWORD = $previousPassword; $env:PGPASSFILE = $previousPassfile }
}
function PgWaitReady([int]$minutes) {
    $deadline = (Get-Date).AddMinutes($minutes)
    while (-not (PgReady) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    PgReady
}
function OperatorSid {
    $opConfigPath = Join-Path $PSScriptRoot ('installation\' + $env:COMPUTERNAME.ToLowerInvariant() + '-operator.json')
    if (Test-Path -LiteralPath $opConfigPath) {
        return (Get-Content -LiteralPath $opConfigPath -Raw | ConvertFrom-Json).windows_sid
    }
    return ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
}
# the service's account: modify the data and the logs, read the install (setup.sh: chown postgres)
function GrantPg {
    $opSid = OperatorSid
    foreach ($d in @($PgData, $PgWal, $PgTemp, $PgLogs)) {
        if ($d -and (Test-Path $d)) {
            $grants = @('/grant', '*S-1-5-20:(OI)(CI)M')
            if ($opSid) { $grants += @('/grant', "*${opSid}:(OI)(CI)F") }
            & icacls.exe $d @grants /T /Q | Out-Null; if ($LASTEXITCODE) { throw "icacls $d exited $LASTEXITCODE" }
        }
    }
    $dirGrants = @('/grant', '*S-1-5-20:(OI)(CI)RX')
    if ($opSid) { $dirGrants += @('/grant', "*${opSid}:(OI)(CI)F") }
    & icacls.exe $PgDir @dirGrants /T /Q | Out-Null; if ($LASTEXITCODE) { throw "icacls $PgDir exited $LASTEXITCODE" }
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    if ($svc -and $opSid) {
        $sddlOut = (& sc.exe sdshow $PgService 2>$null | Where-Object { $_ -match '^D:' } | Select-Object -First 1)
        if ($sddlOut -and $sddlOut -notmatch [regex]::Escape($opSid)) {
            $ace = "(A;;CCLCSWRPWPDTLOCRRC;;;$opSid)"
            $newSddl = if ($sddlOut -match '^(D:[^\(]*(?:\([^\)]+\))*)(S:.*)$') { "$($Matches[1])$ace$($Matches[2])" } else { "$sddlOut$ace" }
            & sc.exe sdset $PgService $newSddl | Out-Null
        }
    }
}
# The floating-point contract as one text (toolchain\determinism.tsv). A build records the contract it was made under
# beside what it installed, and is made again when the contract has changed since: a build tree keeps the flags it was
# configured with, so it is made fresh.
function Contract { ((Get-Content (Join-Path $PSScriptRoot 'toolchain\determinism.tsv') | Where-Object { $_ -match '^[a-z]' }) -join "`n") }
function ContractMark($r) { Join-Path (Prefix $r) ".contract-$($r.name)" }
function DependencyContract($r) {
    $value = Contract
    if ($r.name -eq 'lz4') { $value += "`nlz4-windows-decoder-v1: /clang:-fno-vectorize" }
    if ($r.name -eq 'zstd') { $value += "`nzstd-windows-decoder-v1: /clang:-fno-vectorize" }
    if ($r.name -eq 'postgresql') { $value += "`npostgresql-windows-int128-struct-align-v1" }
    $value
}
# The server stopped around a step that replaces files it holds open (its own binaries, the DLLs beside them): the
# service, elevated, never under an ingest; a hand-started server is not touched and the step is refused.
function WithServerStopped([string]$what, [scriptblock]$body) {
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    $running = [bool]($svc -and $svc.Status -eq 'Running')
    if (-not $svc -and (Test-Path (Join-Path $PgData 'postmaster.pid'))) { throw "$what replaces files the hand-started server holds; stop it first" }
    if ($running -and (TuneIngesting)) { throw "$what needs the server stopped, and an ingest is running" }
    if ($running) {
        Stop-Service -Name $PgService -Force -ErrorAction SilentlyContinue
        if ((Get-Service -Name $PgService).Status -ne 'Stopped') {
            & sc.exe stop $PgService | Out-Null
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Service -Name $PgService).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        }
        if ((Get-Service -Name $PgService).Status -ne 'Stopped') { throw "$what replaces files the running server holds; elevated, or stop $PgService first" }
        Say $what "$PgService stopped"
    }
    try { & $body }
    finally {
        if ($running) {
            Start-Service -Name $PgService -ErrorAction SilentlyContinue
            if ((Get-Service -Name $PgService).Status -ne 'Running') { & sc.exe start $PgService | Out-Null }
            if (PgWaitReady 120) { Say $what "$PgService started" } else { Say $what "$PgService DID NOT START; see its log" }
        }
    }
}
# The dependency manifest (dependencies.tsv), this platform's rows, in file order; the row's prefix, and the file that
# proves it installed (proof, relative to the prefix: the checkout for a row built into Laplace, PostgreSQL's prefix
# for PostGIS, <deps>\<name>\<version> for everything else).
function Manifest {
    $cols = $null
    foreach ($line in Get-Content (Join-Path $PSScriptRoot 'dependencies.tsv')) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        if (-not $cols) { $cols = $f; continue }
        $row = [ordered]@{}; for ($i = 0; $i -lt $cols.Count; $i++) { $row[$cols[$i]] = if ($i -lt $f.Count -and $f[$i] -ne '-') { $f[$i] } else { '' } }
        if (($row.platforms -split ',') -contains 'windows') { [pscustomobject]$row }
    }
}
function Prefix($r) {
    if ($r.build -eq 'none' -and $r.kind -eq 'source') { return Join-Path $DepSrc $r.name }
    if ($r.name -eq 'postgis') { return $PgDir }
    Join-Path (Join-Path $Deps $r.name) $r.version
}
function Proof($r) { if ($r.proof) { Join-Path (Prefix $r) $r.proof } }
function Checkout($r) { if ($r.kind -eq 'release' -and $r.build -eq 'amalgamation') { Join-Path (Join-Path (Join-Path $DepSrc $r.name) $r.version) 'source' } else { Join-Path $DepSrc $r.name } }
# MSYS2: the machine's own when it names one (LAPLACE_MSYS2), else where the manifest's msys2 row is unpacked (deps)
$Msys2 = if ($env:LAPLACE_MSYS2) { $env:LAPLACE_MSYS2 } else { $m = Manifest | Where-Object build -eq 'sfx' | Select-Object -First 1; if ($m) { Prefix $m } }
function DependsPrefixes($r) { foreach ($d in ($r.depends -split ',')) { if ($d) { $row = Manifest | Where-Object name -eq $d | Select-Object -First 1; if ($row -and $row.kind -ne 'tool') { Prefix $row } } } }

# ------------------------------------------------------------------------------------------------------ the parts
# Drives are not made here: Windows has no volume to create or mount, so each root is reported on its drive, with the
# room there, and its directory made. The cluster's own directories are cluster's (initdb wants them absent).
function volumes {
    Part 'volumes'
    $roots = [ordered]@{ 'sources (LAPLACE_SRC)' = $Src; 'builds (LAPLACE_BUILD)' = $Build; 'work (LAPLACE_WORK)' = $Work; 'dependency sources (LAPLACE_DEPSRC)' = $DepSrc
                         'dependencies (LAPLACE_DEPS)' = $Deps; 'data (LAPLACE_DATA)' = $Data; 'cluster (LAPLACE_PGDATA)' = $PgData; 'write-ahead log (LAPLACE_PGWAL)' = $PgWal; 'locks (LAPLACE_LOCKS)' = $Locks }
    if ($PgTemp) { $roots['temporary files (LAPLACE_PGTEMP)'] = $PgTemp }
    foreach ($k in $roots.Keys) {
        $p = $roots[$k]; $d = DriveOf $p
        $drive = Get-PSDrive -Name $d -ErrorAction SilentlyContinue
        if (-not $drive) { Say $k "$p   DRIVE ${d}: IS NOT ON THIS MACHINE"; $failed.Add("volumes: no drive ${d}: for $p"); continue }
        $made = ''
        if ($p -notin @($PgData, $PgWal, $PgTemp) -and -not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null; $made = '   made' }
        Say $k ('{0}   {1}: {2} GB, {3} GB free{4}' -f $p, $d, [int](($drive.Used + $drive.Free) / 1GB), [int]($drive.Free / 1GB), $made)
    }
    New-Item -ItemType Directory -Force $PgLogs | Out-Null
    Say 'shared trees' 'the operator owns them; the service reads the install and owns its data and logs (rights)'
}
# The toolchain is installed by hand (Visual Studio, oneAPI, CMake, Git, uv) or by the manifest (deps); nothing is
# downloaded here but MSYS2's packages. What is missing is said, with where it comes from.
function packages {
    Part 'packages'
    if (Test-Path $DevShell) { Say 'developer shell' "$DevShell$(if (DevShell) { '' } else { '   icx NOT FOUND after loading it' })" }
    else { Say 'developer shell' "MISSING: $DevShell (LAPLACE_DEVSHELL): the repository's is toolchain\windows\devshell.ps1" }
    foreach ($t in $Tools.Keys) {
        $c = Get-Command "$t.exe" -ErrorAction SilentlyContinue
        if (-not $c) { Say $t "MISSING: $($Tools[$t])"; continue }
        $v = switch ($t) { 'icx' { (& icx.exe --version 2>$null | Select-Object -First 1) -replace '^.*?(\d+\.\d+\.\d+).*$', '$1' } 'cmake' { (& cmake.exe --version | Select-Object -First 1) -replace '^.* ', '' }
                           'ninja' { & ninja.exe --version } 'git' { (& git.exe --version) -replace '^git version ', '' } 'uv' { (& uv.exe --version) -replace '^uv ', '' } 'meson' { & meson.exe --version }
                           'perl' { (& perl.exe -e 'print $^V') -replace '^v', '' } 'win_bison' { (& win_bison.exe --version | Select-Object -First 1) -replace '^.* ', '' } 'nasm' { (& nasm.exe -v) -replace '^NASM version (\S+).*$', '$1' } }
        if ($t -eq 'cmake' -and [version]($v -replace '-.*$') -lt [version]'3.25') { Say $t "$v at $($c.Source): TOO OLD, 3.25 or newer (4.x for icx 2026)" } else { Say $t "$v   $($c.Source)" }
    }
    $pacman = Join-Path $Msys2 'usr\bin\pacman.exe'
    if (-not (Test-Path $pacman)) { Say 'MSYS2' "not unpacked yet at ${Msys2}: deps unpacks the manifest's msys2 row there, and this part then installs its packages"; return }
    $missing = @(foreach ($p in $Msys2Packages) { & $pacman -Q $p 2>$null | Out-Null; if ($LASTEXITCODE) { $p } })
    if ($missing.Count) { Attempt 'MSYS2 packages' { Exec $pacman (@('-S', '--needed', '--noconfirm') + $missing); Say 'MSYS2 packages' "installed $($missing -join ' ')" } }
    else { Say 'MSYS2 packages' "all $($Msys2Packages.Count) present at $Msys2" }
}
# Rights: the service's account over the data and the logs and into the install, nothing more; the canonical
# password administrators' only. There is no sudo to remove: no agent runs on this machine (the runner is the Linux
# machine's), and an elevated step is a person's, here.
function rights {
    Part 'rights'
    if (-not (Elevated 'rights')) { return }
    Attempt 'rights' { GrantPg; Say $PgAccount "modify $PgData$(if ($PgWal -ne "$PgData\pg_wal") { ", $PgWal" })$(if ($PgTemp) { ", $PgTemp" }), $PgLogs; read $PgDir" }
    if (Test-Path $PgCanon) {
        $opSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' "*${opSid}:F" /Q | Out-Null
        Say $PgCanon "administrators and $opSid"
    }
    Say 'agents' 'none on this machine; nothing runs elevated but this'
}
# Dependencies: every manifest row present at its pin, then every row the manifest says to build, built and installed
# into its own prefix, each known by the file it installs. A source is a checkout at its exact commit: cloned when
# missing, moved to the pin only when its working tree is clean (local changes are reported, never reset). A release
# or tool is an archive, verified by SHA-256 before it is unpacked into its own prefix; a row without a pin is
# downloaded, its hash printed, and not used until that hash is written into the manifest. The builds run in the
# developer shell under the floating-point contract (toolchain\laplace.cmake; toolchain\meson-native.py), laplace-math
# first, and PostGIS last under MSYS2 (toolchain\windows\postgis.sh).
function deps([string[]]$Names, [switch]$SkipRuntimeClosure) {
    Part 'dependencies'
    $saltyDepsInstaller = @($env:SALTY_SUITE_ROOT, (Join-Path (Split-Path $PSScriptRoot -Parent) 'Salty-Suite'), (Join-Path $PSScriptRoot 'Salty-Suite')) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ 'deps-installer\deps_installer.py' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($saltyDepsInstaller) {
        $pyExe = Get-Command python, python3, py -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1 -ExpandProperty Source
        if ($pyExe) {
            $planArgs = if ($pyExe -match '\\py\.exe$') { @('-3', $saltyDepsInstaller) } else { @($saltyDepsInstaller) }
            $planArgs += @('--manifest', (Join-Path $PSScriptRoot 'dependencies.tsv'), '--platform', 'windows', '--plan', '--format', 'json')
            $null = & $pyExe @planArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Salty-Suite deps-installer manifest validation failed for dependencies.tsv (exit $LASTEXITCODE)" }
        }
    }
    $rows = @(Manifest)
    if ($Names.Count) {
        $rows = @($rows | Where-Object name -In $Names)
        foreach ($name in $Names) { if ($name -notin $rows.name) { throw "Unknown dependency: $name" } }
    }
    foreach ($r in $rows) {
        $what = "$($r.name) $($r.version)"
        if ($r.kind -eq 'source') {
            Attempt $what {
                $dir = Join-Path $DepSrc $r.name
                if (-not (Test-Path (Join-Path $dir '.git'))) {
                    & git.exe clone -q --filter=blob:none --no-checkout $r.origin $dir 2>&1 | Out-Null
                    if ($LASTEXITCODE) { throw "clone failed: $($r.origin)" }
                }
                $origin = (GitIn $dir remote get-url origin | Select-Object -First 1)
                if ($origin.TrimEnd('/') -replace '\.git$' -ne ($r.origin.TrimEnd('/') -replace '\.git$')) { throw "checkout's origin is $origin, the manifest says $($r.origin)" }
                $head = (GitIn $dir rev-parse HEAD | Select-Object -First 1)
                $fresh = -not (Test-Path (Join-Path $dir '.git\index'))           # cloned, never checked out: nothing to keep
                if ($head -eq $r.pin -and -not $fresh) { Say $what "at $($r.pin.Substring(0,12))"; return }
                if (-not $fresh -and (GitIn $dir status --porcelain --untracked-files=no)) { throw "has local changes at $head; not moved to $($r.pin)" }
                GitIn $dir fetch -q origin $r.pin | Out-Null
                GitIn $dir -c advice.detachedHead=false checkout -q $r.pin | Out-Null
                if ((GitIn $dir rev-parse HEAD | Select-Object -First 1) -ne $r.pin) { throw "could not check out $($r.pin)" }
                Say $what "checked out $($r.pin.Substring(0,12))"
            }
        } elseif ($r.kind -in 'release', 'tool') {
            # unpack: an archive whose contents are the install. sfx: a self-extracting archive (MSYS2), likewise, and
            # passed over when the machine's MSYS2 (LAPLACE_MSYS2) is already there. amalgamation: a source archive,
            # unpacked in the source store for the build below. Anything else is installed another way (uv tool).
            if (-not $r.origin.StartsWith('https://') -or $r.build -notin 'unpack', 'sfx', 'amalgamation') { continue }
            if ($r.build -eq 'sfx' -and (Test-Path (Join-Path $Msys2 'usr\bin\bash.exe'))) { Say $what "MSYS2 is at $Msys2"; continue }
            Attempt $what {
                $store = Join-Path (Join-Path $DepSrc $r.name) $r.version
                $prefix = if ($r.build -eq 'amalgamation') { Join-Path $store 'source' } else { Prefix $r }
                if (Test-Path (Join-Path $prefix '.pin')) {
                    if ((Get-Content (Join-Path $prefix '.pin') -Raw).Trim() -eq $r.pin) { Say $what "at $prefix"; return }
                    throw "$prefix holds another archive than the pin; remove it to reinstall"
                }
                New-Item -ItemType Directory -Force $store | Out-Null
                $file = Join-Path $store ([IO.Path]::GetFileName(([uri]$r.origin).AbsolutePath))
                if (-not (Test-Path $file)) { & curl.exe -fsSL --retry 3 -o $file $r.origin; if ($LASTEXITCODE) { Remove-Item $file -ErrorAction SilentlyContinue; throw "download failed: $($r.origin)" } }
                $sha = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
                if (-not $r.pin) { throw "no pin in dependencies.tsv; downloaded $file with SHA-256 ${sha}: review it, write the hash into the manifest, run again" }
                if ($sha -ne $r.pin) { throw "SHA-256 $sha differs from the pin $($r.pin)" }
                $stage = "$prefix.part"; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                if ($r.build -eq 'sfx') { $p = Start-Process -FilePath $file -ArgumentList @('-y', "-o$stage") -Wait -PassThru -WindowStyle Hidden; if ($p.ExitCode) { throw "$file exited $($p.ExitCode)" } }
                elseif ($file -match '\.tar\.(xz|gz|bz2)$') { New-Item -ItemType Directory -Force $stage | Out-Null; & tar.exe -xf $file -C $stage; if ($LASTEXITCODE) { throw "tar could not unpack $file" } }   # Windows' bsdtar
                else { Expand-Archive -LiteralPath $file -DestinationPath $stage }
                $inner = @(Get-ChildItem $stage); if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $stage = $inner[0].FullName }   # one top folder: its contents are the prefix
                New-Item -ItemType Directory -Force (Split-Path $prefix) | Out-Null
                Move-Item -LiteralPath $stage -Destination $prefix
                Remove-Item "$prefix.part" -Recurse -Force -ErrorAction SilentlyContinue
                Set-Content (Join-Path $prefix '.pin') $r.pin
                Say $what "at $prefix"
            }
        } elseif ($r.kind -eq 'data') {
            # a file the chess lab reads, at $LAPLACE_DATA\<proof>: the download verified by its pin, then the file
            # itself (build file) or the one file its zip holds (build zip), kept beside a .sha256 of what it is
            Attempt $what {
                $target = Join-Path $Data ($r.proof -replace '/', '\')
                $mark = "$target.sha256"
                if ((Test-Path $target) -and (Test-Path $mark) -and (Get-Content $mark -Raw).Trim() -eq (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()) { Say $what "at $target"; return }
                if ($r.build -eq 'file' -and (Test-Path $target) -and (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $r.pin) {
                    Set-Content $mark $r.pin; Say $what "at $target (verified)"; return
                }
                $store = Join-Path (Join-Path $DepSrc $r.name) $r.version
                New-Item -ItemType Directory -Force $store, (Split-Path $target) | Out-Null
                $file = Join-Path $store ([IO.Path]::GetFileName(([uri]$r.origin).AbsolutePath))
                if (-not (Test-Path $file)) { & curl.exe -fsSL --retry 3 -o $file $r.origin; if ($LASTEXITCODE) { Remove-Item $file -ErrorAction SilentlyContinue; throw "download failed: $($r.origin)" } }
                $sha = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($sha -ne $r.pin) { throw "SHA-256 $sha differs from the pin $($r.pin)" }
                if ($r.build -eq 'zip') {
                    $stage = "$target.part"; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                    Expand-Archive -LiteralPath $file -DestinationPath $stage
                    $inner = @(Get-ChildItem $stage -File -Recurse); if ($inner.Count -ne 1) { throw "$file holds $($inner.Count) files, not one" }
                    Move-Item -Force $inner[0].FullName $target; Remove-Item $stage -Recurse -Force
                } else { Copy-Item -Force $file $target }
                Set-Content $mark (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
                Say $what "at $target"
            }
        }
    }

    # the builds
    $toBuild = @($rows | Where-Object { $_.build -in 'cmake', 'openssl', 'amalgamation', 'meson', 'configure', 'headers' })
    $missing = @($toBuild | Where-Object { -not (Test-Path (Proof $_)) })
    if (-not (Test-Path $Math) -or $missing.Count) {
        if (-not (DevShell)) { Say 'builds' "NOT BUILT: no icx; the developer shell $DevShell is missing or does not provide it"; $failed.Add('deps: no icx'); return }
    }
    $mathMark = Join-Path (Split-Path $Math) '.contract'
    if ((Test-Path $Math) -and (Test-Path $mathMark) -and (Get-Content $mathMark -Raw) -eq (Contract)) { Say 'laplace-math' $Math }
    else {
        if ($Names.Count) { throw 'The declared math contract must be installed by setup.ps1 deps before targeted codec repair.' }
        if (Test-Path $Math) { Say 'laplace-math' $(if (Test-Path $mathMark) { 'the contract changed since it was built: built again' } else { 'built before the contract was recorded: built again' }) }
        if (-not (DevShell)) { Say 'laplace-math' "NOT BUILT: no icx; the developer shell $DevShell is missing or does not provide it"; $failed.Add('deps: no icx'); return }
        Attempt 'laplace-math' {
            $b = Split-Path $Math
            if (Test-Path $b) { Remove-Item $b -Recurse -Force }
            # the one build that needs no LAPLACE_MATH: the toolchain file reads the environment's in every compiler probe and
            # would refuse it, since it is this library, so the variable is out of the environment while it builds
            $saved = $env:LAPLACE_MATH; Remove-Item Env:LAPLACE_MATH
            try {
                Exec cmake.exe @('-S', (Join-Path $PSScriptRoot 'math'), '-B', $b, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_TOOLCHAIN_FILE=$Toolchain", "-DCORE_MATH=$env:LAPLACE_COREMATH")
                Exec cmake.exe @('--build', $b)
            } finally { $env:LAPLACE_MATH = $saved }
            if (-not (Test-Path $Math)) { throw "no library at $Math" }
            Set-Content -Path $mathMark -Value (Contract) -NoNewline
            Say 'laplace-math' "built: $Math"
        }
    }
    foreach ($r in $toBuild) {
        $what = "$($r.name) $($r.version)"
        $proof = Proof $r; $prefix = Prefix $r; $checkout = Checkout $r; $b = Join-Path (Join-Path $Build 'deps') $r.name
        if (-not $proof) { Say $what 'NO PROOF in dependencies.tsv: not built'; continue }
        $mark = ContractMark $r; $compiled = $r.build -ne 'headers'
        if (Test-Path $proof) {
            if (-not $compiled -or ((Test-Path $mark) -and (Get-Content $mark -Raw) -eq (DependencyContract $r))) {
                if ($r.name -eq 'lz4') { & "$PSScriptRoot/tests/windows-lz4.ps1" -Library (Join-Path $prefix 'bin/lz4.dll') -BuildDirectory (Join-Path $b 'regression') }
                if ($r.name -eq 'zstd') { & "$PSScriptRoot/tests/windows-zstd.ps1" -Library (Join-Path $prefix 'bin/zstd.dll') -BuildDirectory (Join-Path $b 'regression') }
                Say $what "installed at $prefix"; continue
            }
            Say $what $(if (Test-Path $mark) { 'the contract changed since it was built: built again' } else { 'built before the contract was recorded: built again' })
        }
        if (-not (Test-Path $checkout)) { Say $what "NOT BUILT: no source at $checkout"; continue }
        if (-not (DevShell)) { Say $what "NOT BUILT: no icx; the developer shell $DevShell is missing or does not provide it"; $failed.Add('deps: no icx'); continue }
        $libs = @(DependsPrefixes $r)
        Attempt $what {
            if (-not $Names.Count -and (Test-Path $b)) { Remove-Item $b -Recurse -Force }
            New-Item -ItemType Directory -Force $b | Out-Null
            switch ($r.build) {
                'cmake' {
                    if ($DepSourceDir[$r.name]) { $checkout = Join-Path $checkout $DepSourceDir[$r.name] }
                    $opts = @('--fresh', '-S', $checkout, '-B', $b, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_TOOLCHAIN_FILE=$Toolchain", "-DLAPLACE_MATH=$Math",
                              "-DCMAKE_INSTALL_PREFIX=$prefix", '-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON')
                    if ($libs.Count) { $opts += "-DCMAKE_PREFIX_PATH=$(($libs -replace '\\', '/') -join ';')" }
                    if ($DepOptions[$r.name]) { $opts += $DepOptions[$r.name] }
                    Exec cmake.exe $opts; Exec cmake.exe @('--build', $b); Exec cmake.exe @('--install', $b)
                }
                'openssl' {
                    $zlib = $libs | Where-Object { $_ -match '\\zlib\\' } | Select-Object -First 1
                    if (-not $zlib) { throw 'openssl depends on zlib, which the manifest does not name' }
                    # Strawberry Perl, the manifest's, by name: the first perl on the path may be Git's, whose modules are Unix's
                    $perlRow = $rows | Where-Object name -eq 'strawberry-perl' | Select-Object -First 1
                    $perl = if ($perlRow) { Join-Path (Prefix $perlRow) 'perl\bin\perl.exe' } else { 'perl.exe' }
                    if (-not (Test-Path $perl)) { throw "no Strawberry Perl at $perl (dependencies.tsv)" }
                    Push-Location $b
                    try {
                        if (-not (Test-Path 'configdata.pm')) { Exec $perl @((Join-Path $checkout 'Configure'), 'VC-WIN64A', 'CC=icx', "--prefix=$prefix", "--openssldir=$prefix\ssl", 'no-tests', 'shared', 'zlib', "--with-zlib-include=$zlib\include", "--with-zlib-lib=$zlib\lib\z.lib") }
                        Exec nmake.exe @(); Exec nmake.exe @('install_sw')
                    } finally { Pop-Location }
                }
                'amalgamation' {
                    # the contract's compile flags for the MSVC driver, and the link that ends with laplace-math (toolchain\laplace.cmake)
                    $fp = @(Get-Content (Join-Path $PSScriptRoot 'toolchain\determinism.tsv') | Where-Object { $_ -match '^compile\t(msvc|any)\t' } | ForEach-Object { ($_ -split "`t")[2] })
                    $link = @('/link', '/NODEFAULTLIB:libmmd.lib', $Math, 'libmmd.lib')
                    Push-Location $b
                    try {
                        Exec icx.exe (@('/nologo', '/O2', '/MD') + $fp + $SqliteDefines + @('/DSQLITE_API=__declspec(dllexport)', '/LD', (Join-Path $checkout 'sqlite3.c'), '/Fe:sqlite3.dll') + $link)
                        Exec icx.exe (@('/nologo', '/O2', '/MD') + $fp + $SqliteDefines + @((Join-Path $checkout 'shell.c'), (Join-Path $checkout 'sqlite3.c'), '/Fe:sqlite3.exe') + $link)
                    } finally { Pop-Location }
                    foreach ($d in 'bin', 'lib', 'include') { New-Item -ItemType Directory -Force (Join-Path $prefix $d) | Out-Null }
                    Copy-Item (Join-Path $b 'sqlite3.dll'), (Join-Path $b 'sqlite3.exe') (Join-Path $prefix 'bin'); Copy-Item (Join-Path $b 'sqlite3.lib') (Join-Path $prefix 'lib')
                    Copy-Item (Join-Path $checkout 'sqlite3.h'), (Join-Path $checkout 'sqlite3ext.h') (Join-Path $prefix 'include')
                }
                'meson' {
                    # the patches, each applied once; the contract as a native file; the libraries from the manifest's depends
                    Push-Location $checkout
                    try {
                        & git.exe checkout -- . 2>$null
                        foreach ($p in (Get-ChildItem (Join-Path $PSScriptRoot 'patches\postgresql') -Filter '*.patch' | Sort-Object Name)) {
                            Exec git.exe @('apply', $p.FullName)
                        }
                    }
                    finally { Pop-Location }
                    $native = Join-Path (Join-Path $Build 'deps') 'pg-native.ini'
                    # uv brings the Python: the machine declares uv (packages), not a python on the PATH
                    & uv.exe run --no-project --quiet (Join-Path $PSScriptRoot 'toolchain\meson-native.py') msvc $Math | Set-Content $native
                    if ($LASTEXITCODE) { throw 'meson-native.py failed' }
                    $inc = ($libs | ForEach-Object { "$_\include" -replace '\\', '/' }) -join ','
                    $lib = ($libs | ForEach-Object { foreach ($l in 'lib', 'lib64') { if (Test-Path "$_\$l") { "$_\$l" -replace '\\', '/' } } }) -join ','
                    # ICU's Windows release carries no pkg-config or CMake package: Meson's CMake probe finds it, and the rest, by prefix
                    $cmakePrefix = ($libs -replace '\\', '/') -join ','
                    if (-not (Test-Path (Join-Path $b 'build.ninja'))) { Exec meson.exe (@('setup', $b, $checkout, "--native-file=$native", "-Dprefix=$prefix", "-Dextra_include_dirs=$inc", "-Dextra_lib_dirs=$lib", "-Dcmake_prefix_path=$cmakePrefix") + $PgMesonOptions) }
                    Exec ninja.exe @('-C', $b)
                    WithServerStopped $what { Exec ninja.exe @('-C', $b, 'install') }
                }
                'configure' {
                    # PostGIS: toolchain\windows\postgis.sh in MSYS2's shell, started from the developer shell
                    $bash = Join-Path $Msys2 'usr\bin\bash.exe'
                    if (-not (Test-Path $bash)) { throw "no MSYS2 at $Msys2 (LAPLACE_MSYS2)" }
                    $env:MSYSTEM = 'MSYS'; $env:MSYS2_PATH_TYPE = 'inherit'; $env:CHERE_INVOKING = '1'
                    $sh = MsysPath (Join-Path $PSScriptRoot 'toolchain\windows\postgis.sh')
                    try {
                        Exec $bash @('-l', '-c', "$sh configure build")
                        WithServerStopped $what { Exec $bash @('-l', '-c', "$sh install") }   # the DLLs go beside postgres.exe
                    } finally { Remove-Item Env:MSYSTEM, Env:MSYS2_PATH_TYPE, Env:CHERE_INVOKING -ErrorAction SilentlyContinue }
                }
                'headers' {
                    foreach ($h in $DepHeaders[$r.name]) {
                        $to = Join-Path $prefix $h.To; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
                        Remove-Item $to -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item (Join-Path $checkout $h.From) $to -Recurse
                    }
                }
            }
            if (-not (Test-Path $proof)) { throw "DID NOT INSTALL: no $proof; the build is $b" }
            if ($r.name -eq 'lz4') { & "$PSScriptRoot/tests/windows-lz4.ps1" -Library (Join-Path $prefix 'bin/lz4.dll') -BuildDirectory (Join-Path $b 'regression') }
            if ($r.name -eq 'zstd') { & "$PSScriptRoot/tests/windows-zstd.ps1" -Library (Join-Path $prefix 'bin/zstd.dll') -BuildDirectory (Join-Path $b 'regression') }
            if ($compiled) { Set-Content -Path $mark -Value (DependencyContract $r) -NoNewline }
            Say $what "built and installed at $prefix"
        }
    }
    if ($Names.Count -and $failed.Count) { throw ($failed -join '; ') }
    if (-not $Names.Count) { Attempt 'Tree-sitter grammar generator' { & "$PSScriptRoot/installation/build-tree-sitter.ps1" } }
    if (-not $SkipRuntimeClosure) { Attempt 'runtime closure' { RuntimeClosure } }
}
# What PostgreSQL loads, beside it. Its service runs as NetworkService and reads no person's PATH (Operations#2), and
# the libraries it was built against are each under a prefix of their own (ICU, zlib, lz4, zstd, OpenSSL, libxml2;
# GEOS, PROJ and theirs for PostGIS) with the compiler's runtime under oneAPI: none of that is found by a service, and
# a client's PostgreSQL on the PATH would be found in their place. Every library the installed programs and modules
# import, and what those import in turn, is copied into PostgreSQL's bin when it is one of ours (a manifest prefix or
# the compiler's runtime); Windows' own are left to Windows. Read from the files themselves (dumpbin /dependents).
function RuntimeClosure {
    if (-not (Test-Path (Join-Path $PgBin 'postgres.exe'))) { Say 'runtime closure' 'no PostgreSQL installed yet'; return }
    if (-not (DevShell) -or -not (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) { throw 'no dumpbin: the developer shell does not provide Visual Studio''s tools' }
    $from = [Collections.Generic.List[string]]::new()
    foreach ($r in (Manifest | Where-Object { $_.kind -ne 'tool' -and $_.name -ne 'postgis' })) { foreach ($s in 'bin', 'bin64', 'lib') { $d = Join-Path (Prefix $r) $s; if (Test-Path $d) { $from.Add($d) } } }
    $rt = Split-Path (Get-Command icx.exe).Source; if (Test-Path (Join-Path $rt 'libmmd.dll')) { $from.Add($rt) }
    $have = @{}; Get-ChildItem $PgBin -Filter *.dll | ForEach-Object { $have[$_.Name.ToLowerInvariant()] = $true }
    $queue = [Collections.Generic.Queue[string]]::new()
    Get-ChildItem $PgBin, (Join-Path $PgDir 'lib') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object { $queue.Enqueue($_.FullName) }
    $seen = @{}; $copied = [Collections.Generic.List[string]]::new()
    while ($queue.Count) {
        $file = $queue.Dequeue(); if ($seen[$file]) { continue }; $seen[$file] = $true
        foreach ($line in (& dumpbin.exe /nologo /dependents $file 2>$null)) {
            $name = $line.Trim(); if ($name -notmatch '^[\w.+-]+\.dll$') { continue }
            $key = $name.ToLowerInvariant()
            if ($have[$key]) {
                # Existing codec copies must not survive a corrected dependency rebuild.
                if ($key -in 'lz4.dll', 'zstd.dll') {
                    $codec = [IO.Path]::GetFileNameWithoutExtension($key)
                    $expected = $from | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path $_ } | Select-Object -First 1
                    $installed = Join-Path $PgBin $name
                    if ($expected -and (Get-FileHash -LiteralPath $expected).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
                        & "$PSScriptRoot/tests/windows-$codec.ps1" -Library $expected -BuildDirectory (Join-Path $Build "deps/$codec/regression")
                        WithServerStopped "$codec runtime refresh" {
                            $backup = Join-Path $logDir ("$codec-before-"+[guid]::NewGuid().ToString('N')+'.dll')
                            Copy-Item -LiteralPath $installed -Destination $backup
                            try {
                                Copy-Item -LiteralPath $expected -Destination $installed -Force
                                if ((Get-FileHash -LiteralPath $expected).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) { throw "Installed $codec hash differs after runtime refresh" }
                                & "$PSScriptRoot/tests/windows-$codec.ps1" -Library $installed -BuildDirectory (Join-Path $Build "deps/$codec/regression")
                            } catch { Copy-Item -LiteralPath $backup -Destination $installed -Force; throw }
                        }
                    }
                }
                continue
            }
            $src = $from | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $src) { continue }                                       # not ours: Windows' own, or the C runtime
            Copy-Item -LiteralPath $src -Destination $PgBin; $have[$key] = $true; $copied.Add($name); $queue.Enqueue((Join-Path $PgBin $name))
        }
    }
    $v = & (Join-Path $PgBin 'postgres.exe') --version 2>&1
    if ($LASTEXITCODE) { throw "postgres.exe does not start from its own directory (exit $LASTEXITCODE): a library it loads is in none of the manifest's prefixes" }
    Say 'runtime closure' "$(if ($copied.Count) { "copied $($copied.Count) beside postgres.exe: $($copied -join ' ')" } else { 'complete' }); $v"
}
$OpsRoot = $PSScriptRoot
. "$PSScriptRoot/installation/setup-desktop.ps1"

$known = 'all', 'drop', 'volumes', 'packages', 'rights', 'deps', 'postgres', 'repair-postgres', 'cluster', 'settings', 'access', 'report', 'network', 'shares', 'services', 'firewall', 'backup', 'status'
foreach ($p in $Parts) { if ($known -notcontains $p) { "setup.ps1 [drop] [$(($known | Select-Object -Skip 1) -join '|') ...]"; Stop-Transcript | Out-Null; exit 2 } }
# status: the desktop's own parts named with it (all three, when none is) report and change nothing
$Status = $Parts -contains 'status'
if ($Status) {
    $Parts = @($Parts | Where-Object { $_ -ne 'status' }); if (-not $Parts.Count) { $Parts = 'shares', 'services', 'firewall', 'backup' }
    $other = @($Parts | Where-Object { $_ -notin 'network', 'shares', 'services', 'firewall', 'backup' })
    if ($other.Count) { "setup.ps1 status reports shares, services, firewall and backup; $($other -join ', ') has none (report)"; Stop-Transcript | Out-Null; exit 2 }
}
function postgres { & "$PSScriptRoot/installation/postgres-installation.ps1" }
. "$PSScriptRoot/installation/storage.ps1"
$storageOperation=if(-not $Status -and -not $ReadOnlyPgRepair -and @($Parts | Where-Object {$_ -ne 'report'}).Count){Enter-DesktopStorageOperation}else{$null}
try { foreach ($p in $Parts) { if ($p -eq 'all') { Install-LaplaceOpsCommand; volumes; packages; rights; deps; postgres; cluster; settings; access; report } else { & $p } } }
catch { "=== $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"; $failed.Add("setup.ps1 stopped: $($_.Exception.Message)") }
finally { try{Exit-DesktopStorageOperation $storageOperation}catch{$failed.Add("cleanup: $($_.Exception.Message)")} }
''
if ($failed.Count) { '=== failed'; $failed | ForEach-Object { "  $_" } }
if ($ReadOnlyPgRepair) { if ($failed.Count) { exit 1 }; return }
"=== done   {0:HH:mm:ss}   $log" -f (Get-Date).ToUniversalTime()
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
