#Requires -Version 7
<#
  The Windows machine Laplace is developed on, declared once and converged: the counterpart of setup.sh (Operations:
  Setup, Database). The same parts, in the same order; each compares its declaration with the machine and makes only
  what is missing, so running it again on a finished machine changes nothing and reports. What it did is kept under
  $LAPLACE_WORK\logs\root. Every name of this machine's is a variable of laplace.env.ps1, so another Windows machine
  declares its own.

    pwsh -File setup.ps1                   everything below, in order (the parts that change the service, its rights,
                                           its settings and its access need an elevated PowerShell and say so)
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
param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Parts = @('all'))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
. "$PSScriptRoot\tune-pg.ps1"

$Src = $env:LAPLACE_SRC; $Build = $env:LAPLACE_BUILD; $Work = $env:LAPLACE_WORK; $DepSrc = $env:LAPLACE_DEPSRC; $Deps = $env:LAPLACE_DEPS; $Data = $env:LAPLACE_DATA
$PgDir = $env:LAPLACE_PG_DIR; $PgBin = Join-Path $PgDir 'bin'; $PgData = $env:LAPLACE_PGDATA; $PgWal = $env:LAPLACE_PGWAL; $PgTemp = $env:LAPLACE_PGTEMP
$PgHost = $env:LAPLACE_PGHOST; $PgPort = $env:LAPLACE_PGPORT; $PgService = $env:LAPLACE_PGSERVICE; $PgAccount = $env:LAPLACE_PGUSER; $PgRole = $env:LAPLACE_ROLE; $PgLan = $env:LAPLACE_LAN; $Locks = $env:LAPLACE_LOCKS
$PgLogs = Join-Path $Work 'logs\postgres'
$PgCanon = 'C:\ProgramData\Laplace\pgpass.conf'   # the role's password: one canonical copy, administrators only (setup.sh: /etc/laplace/pgpass)
$Math = $env:LAPLACE_MATH; $DevShell = $env:LAPLACE_DEVSHELL
$Toolchain = Join-Path $PSScriptRoot 'toolchain\laplace.cmake'

$logDir = Join-Path $Work 'logs\root'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("setup-{0:yyyyMMddTHHmmssZ}.log" -f (Get-Date).ToUniversalTime())
Start-Transcript -Path $log | Out-Null
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
$Msys2Packages = 'autoconf', 'automake', 'libtool', 'make', 'pkgconf', 'mingw-w64-ucrt-x86_64-gcc'
# How each dependency the manifest says to build is configured on Windows: the options beyond the toolchain file,
# the contract and the prefix, as the installs on HART-DESKTOP were made (their build trees' caches, 2026-10-04).
$DepSourceDir = @{ lz4 = 'build\cmake'; zstd = 'build\cmake' }
$DepOptions = @{
    lz4       = @('-DLZ4_BUILD_CLI=OFF', '-DBUILD_STATIC_LIBS=OFF')
    zstd      = @('-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF', '-DZSTD_BUILD_CONTRIB=OFF')
    libxml2   = @('-DLIBXML2_WITH_PROGRAMS=OFF', '-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_ICONV=OFF', '-DLIBXML2_WITH_HTTP=OFF')
    'json-c'  = @('-DBUILD_APPS=OFF')
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
    if (-not (Test-Path $DevShell)) { return [bool](Get-Command icx.exe -ErrorAction SilentlyContinue) }
    . $DevShell *> $null                                                    # again each time: the tools deps unpacked since are put on the PATH
    [bool](Get-Command icx.exe -ErrorAction SilentlyContinue)
}
function PgReady { & "$PgBin\pg_isready.exe" -h $PgHost -p $PgPort 2>$null | Out-Null; $LASTEXITCODE -eq 0 }
# one statement to the server, as a superuser: postgres (trust on a cluster initdb made; its declared password after
# access), else the role with the canonical password
function PgSql([string]$sql) {
    try {
        $env:PGPASSWORD = 'postgres'
        $out = & "$PgBin\psql.exe" -X -h $PgHost -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq -c $sql 2>&1
        if (-not $LASTEXITCODE) { return $out }
        Remove-Item Env:PGPASSWORD; $env:PGPASSFILE = $PgCanon
        $out = & "$PgBin\psql.exe" -X -h $PgHost -p $PgPort -U $PgRole -d postgres -v ON_ERROR_STOP=1 -Atq -c $sql 2>&1
        if ($LASTEXITCODE) { throw "psql: $($out -join ' ')" }
        $out
    } finally { Remove-Item Env:PGPASSWORD, Env:PGPASSFILE -ErrorAction SilentlyContinue }
}
function PgWaitReady([int]$minutes) {
    $deadline = (Get-Date).AddMinutes($minutes)
    while (-not (PgReady) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    PgReady
}
# the service's account: modify the data and the logs, read the install (setup.sh: chown postgres)
function GrantPg {
    foreach ($d in @($PgData, $PgWal, $PgTemp, $PgLogs)) { if ($d -and (Test-Path $d)) { & icacls.exe $d /grant '*S-1-5-20:(OI)(CI)M' /T /Q | Out-Null; if ($LASTEXITCODE) { throw "icacls $d exited $LASTEXITCODE" } } }
    & icacls.exe $PgDir /grant '*S-1-5-20:(OI)(CI)RX' /T /Q | Out-Null; if ($LASTEXITCODE) { throw "icacls $PgDir exited $LASTEXITCODE" }
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
    if (Test-Path $PgCanon) { & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' /Q | Out-Null; Say $PgCanon 'administrators only' }
    Say 'agents' 'none on this machine; nothing runs elevated but this'
}
# Dependencies: every manifest row present at its pin, then every row the manifest says to build, built and installed
# into its own prefix, each known by the file it installs. A source is a checkout at its exact commit: cloned when
# missing, moved to the pin only when its working tree is clean (local changes are reported, never reset). A release
# or tool is an archive, verified by SHA-256 before it is unpacked into its own prefix; a row without a pin is
# downloaded, its hash printed, and not used until that hash is written into the manifest. The builds run in the
# developer shell under the floating-point contract (toolchain\laplace.cmake; toolchain\meson-native.py), laplace-math
# first, and PostGIS last under MSYS2 (toolchain\windows\postgis.sh).
function deps {
    Part 'dependencies'
    $rows = @(Manifest)
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
    if (Test-Path $Math) { Say 'laplace-math' $Math }
    else {
        Attempt 'laplace-math' {
            $b = Split-Path $Math
            # the toolchain refuses a LAPLACE_MATH that names no file, which is every build's protection and this
            # one's obstacle: the library it names is what is being made. It is out of the environment for this build.
            $named = $env:LAPLACE_MATH; $env:LAPLACE_MATH = $null
            try {
                Exec cmake.exe @('-S', (Join-Path $PSScriptRoot 'math'), '-B', $b, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_TOOLCHAIN_FILE=$Toolchain", "-DCORE_MATH=$env:LAPLACE_COREMATH")
                Exec cmake.exe @('--build', $b)
            } finally { $env:LAPLACE_MATH = $named }
            if (-not (Test-Path $Math)) { throw "no library at $Math" }
            Say 'laplace-math' "built: $Math"
        }
    }
    foreach ($r in $toBuild) {
        $what = "$($r.name) $($r.version)"
        $proof = Proof $r; $prefix = Prefix $r; $checkout = Checkout $r; $b = Join-Path (Join-Path $Build 'deps') $r.name
        if (-not $proof) { Say $what 'NO PROOF in dependencies.tsv: not built'; continue }
        if (Test-Path $proof) { Say $what "installed at $prefix"; continue }
        if (-not (Test-Path $checkout)) { Say $what "NOT BUILT: no source at $checkout"; continue }
        $libs = @(DependsPrefixes $r)
        Attempt $what {
            New-Item -ItemType Directory -Force $b | Out-Null
            switch ($r.build) {
                'cmake' {
                    if ($DepSourceDir[$r.name]) { $checkout = Join-Path $checkout $DepSourceDir[$r.name] }
                    $opts = @('-S', $checkout, '-B', $b, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_TOOLCHAIN_FILE=$Toolchain", "-DLAPLACE_MATH=$Math",
                              "-DCMAKE_INSTALL_PREFIX=$prefix", '-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON')
                    if ($libs.Count) { $opts += "-DCMAKE_PREFIX_PATH=$(($libs -replace '\\', '/') -join ';')" }
                    if ($DepOptions[$r.name]) { $opts += $DepOptions[$r.name] }
                    Exec cmake.exe $opts; Exec cmake.exe @('--build', $b); Exec cmake.exe @('--install', $b)
                }
                'openssl' {
                    $zlib = $libs | Where-Object { $_ -match '\\zlib\\' } | Select-Object -First 1
                    if (-not $zlib) { throw 'openssl depends on zlib, which the manifest does not name' }
                    Push-Location $b
                    try {
                        if (-not (Test-Path 'configdata.pm')) { Exec perl.exe @((Join-Path $checkout 'Configure'), 'VC-WIN64A', 'CC=icx', "--prefix=$prefix", "--openssldir=$prefix\ssl", 'no-tests', 'shared', 'zlib', "--with-zlib-include=$zlib\include", "--with-zlib-lib=$zlib\lib\z.lib") }
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
                    try { foreach ($p in Get-ChildItem (Join-Path $PSScriptRoot 'patches\postgresql') -Filter '*.patch') { & git.exe apply --reverse --check $p.FullName 2>$null; if ($LASTEXITCODE) { Exec git.exe @('apply', $p.FullName) } } }
                    finally { Pop-Location }
                    $native = Join-Path (Join-Path $Build 'deps') 'pg-native.ini'
                    & python.exe (Join-Path $PSScriptRoot 'toolchain\meson-native.py') msvc $Math | Set-Content $native
                    if ($LASTEXITCODE) { throw 'meson-native.py failed' }
                    $inc = ($libs | ForEach-Object { "$_\include" -replace '\\', '/' }) -join ','
                    $lib = ($libs | ForEach-Object { foreach ($l in 'lib', 'lib64') { if (Test-Path "$_\$l") { "$_\$l" -replace '\\', '/' } } }) -join ','
                    if (-not (Test-Path (Join-Path $b 'build.ninja'))) { Exec meson.exe (@('setup', $b, $checkout, "--native-file=$native", "-Dprefix=$prefix", "-Dextra_include_dirs=$inc", "-Dextra_lib_dirs=$lib") + $PgMesonOptions) }
                    Exec ninja.exe @('-C', $b); Exec ninja.exe @('-C', $b, 'install')
                }
                'configure' {
                    # PostGIS: toolchain\windows\postgis.sh in MSYS2's shell, started from the developer shell
                    $bash = Join-Path $Msys2 'usr\bin\bash.exe'
                    if (-not (Test-Path $bash)) { throw "no MSYS2 at $Msys2 (LAPLACE_MSYS2)" }
                    $env:MSYSTEM = 'MSYS'; $env:MSYS2_PATH_TYPE = 'inherit'; $env:CHERE_INVOKING = '1'
                    try { Exec $bash @('-l', '-c', (MsysPath (Join-Path $PSScriptRoot 'toolchain\windows\postgis.sh'))) }
                    finally { Remove-Item Env:MSYSTEM, Env:MSYS2_PATH_TYPE, Env:CHERE_INVOKING -ErrorAction SilentlyContinue }
                }
                'headers' {
                    foreach ($h in $DepHeaders[$r.name]) {
                        $to = Join-Path $prefix $h.To; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
                        Remove-Item $to -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item (Join-Path $checkout $h.From) $to -Recurse
                    }
                }
            }
            if (Test-Path $proof) { Say $what "built and installed at $prefix" } else { throw "DID NOT INSTALL: no $proof; the build is $b" }
        }
    }
}
# The cluster: made once (Sequence 8: UTF-8, the C.UTF-8 locale, data checksums, the log where LAPLACE_PGWAL says),
# run as the Windows service, its account over its directories; then the certificate, before ssl = on is declared (a
# server told to use TLS without one does not start), and the temporary tablespace when LAPLACE_PGTEMP names one.
function cluster {
    Part 'cluster'
    if (-not (Elevated 'cluster')) { return }
    if (-not (Test-Path "$PgBin\pg_ctl.exe")) { Say 'cluster' "FAILED: no server at $PgBin (deps)"; $failed.Add("cluster: no server at $PgBin"); return }
    foreach ($d in @((Split-Path $PgData), (Split-Path $PgWal), $PgTemp, $PgLogs)) { if ($d) { New-Item -ItemType Directory -Force $d | Out-Null } }
    if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
        Attempt 'cluster' {
            $opts = @('-D', $PgData, '-U', 'postgres', '--encoding=UTF8', '--locale-provider=builtin', '--locale=C.UTF-8', '--data-checksums')
            if ($PgWal -ne (Join-Path $PgData 'pg_wal')) { $opts += "--waldir=$PgWal" }
            Exec "$PgBin\initdb.exe" $opts
            Say 'cluster' "initialised in $PgData, WAL in $PgWal"
        }
        if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) { return }
    } else {
        $checksums = (& "$PgBin\pg_controldata.exe" $PgData 2>$null | Where-Object { $_ -match 'checksum version:\s+(\d+)' } | ForEach-Object { $Matches[1] })
        Say 'cluster' "$(Get-Content (Join-Path $PgData 'PG_VERSION')) in $PgData$(if ($checksums -eq '0') { '   NO DATA CHECKSUMS: Sequence 8 wants --data-checksums; drop makes the cluster again' })"
    }
    Attempt 'rights' { GrantPg }

    # the service: registered once; a postmaster someone started by hand holds the data directory and is stopped first
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    if (-not $svc) {
        Attempt "service $PgService" {
            if (Test-Path (Join-Path $PgData 'postmaster.pid')) {
                & "$PgBin\pg_ctl.exe" -D $PgData -m fast -w -t 300 stop 2>&1 | Out-Null
                if (Test-Path (Join-Path $PgData 'postmaster.pid')) { & "$PgBin\pg_ctl.exe" -D $PgData -m immediate -w -t 120 stop 2>&1 | Out-Null }
                Get-Process postgres -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $PgData 'postmaster.pid') -ErrorAction SilentlyContinue
                Say 'hand-started server' 'stopped'
            }
            # pg_ctl registers the service as LocalSystem unless -U names the account (pg_ctl.c: register_username NULL);
            # a built-in account takes no password
            $out = & "$PgBin\pg_ctl.exe" register -N $PgService -U $PgAccount -D $PgData -S auto -w 2>&1
            if ($LASTEXITCODE) { throw "pg_ctl register: $($out -join ' ')" }
            Say "service $PgService" "registered: automatic start, as $PgAccount"
        }
        $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    } else { Say "service $PgService" "$($svc.Status), start $($svc.StartType)" }
    if (-not $svc) { return }
    if ($svc.Status -ne 'Running') { Attempt "service $PgService start" { Start-Service -Name $PgService; Say "service $PgService" 'started' } }
    # after an unclean stop the server replays its log before it listens
    if (-not (PgWaitReady 120)) { Say 'cluster' 'FAILED: not accepting connections after two hours; see the log'; $failed.Add('cluster: not ready'); return }
    Say 'cluster' "accepting connections on ${PgHost}:$PgPort ($(PgSql 'SELECT version()'))"
    if ($PgTemp) { Attempt 'tablespace pgtemp' { if ((PgSql "SELECT count(*) FROM pg_tablespace WHERE spcname = 'pgtemp'") -ne '1') { PgSql "CREATE TABLESPACE pgtemp LOCATION '$($PgTemp -replace '\\', '/')'" | Out-Null }; Say 'tablespace pgtemp' $PgTemp } }
    if (-not (Test-Path (Join-Path $PgData 'server.crt'))) {
        Attempt 'certificate' {
            # Git's openssl is self-contained; the manifest's needs zlib's DLL from zlib's own prefix on the PATH (a missing
            # DLL is a dialog, not an exit code)
            $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'; $path = $env:PATH
            if (-not (Test-Path $openssl)) {
                $openssl = Get-ChildItem (Join-Path $Deps 'openssl') -Recurse -Filter openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                if (-not $openssl) { throw "no openssl (Git's, or the manifest's)" }
                $env:PATH = (@(Get-ChildItem (Join-Path $Deps 'zlib') -Directory | ForEach-Object { Join-Path $_.FullName 'bin' }) + $env:PATH) -join ';'
            }
            try { $out = & $openssl req -new -x509 -days 3650 -nodes -subj "/CN=$env:COMPUTERNAME" -keyout (Join-Path $PgData 'server.key') -out (Join-Path $PgData 'server.crt') 2>&1 }
            finally { $env:PATH = $path }
            if ($LASTEXITCODE -or -not (Test-Path (Join-Path $PgData 'server.crt'))) { throw "openssl: $($out -join ' ')" }
            foreach ($f in 'server.key', 'server.crt') { & icacls.exe (Join-Path $PgData $f) /inheritance:r /grant '*S-1-5-20:R' /grant '*S-1-5-32-544:F' /Q | Out-Null }
            Say 'certificate' "self-signed, CN=$env:COMPUTERNAME, 3650 days, readable by $PgAccount"
        }
    } else { Say 'certificate' 'present' }
}
# The cluster dropped, for cluster to make again: the service stopped and deleted, and everything in its data
# directory, its log directory and its temporary directory removed. Every database on the server is lost, so it is
# never part of all, it asks for the data directory by name, and it does not run under an ingest.
function drop {
    Part 'drop'
    if (-not (Elevated 'drop')) { return }
    if ($env:LAPLACE_DROP -ne $PgData) { Say 'drop' "REFUSED: name the cluster to drop: `$env:LAPLACE_DROP = '$PgData'"; $failed.Add('drop: not named'); return }
    if (TuneIngesting) { Say 'drop' 'REFUSED: an ingest is running'; $failed.Add('drop: ingesting'); return }
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    if ($svc) { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $PgService -Force }; & sc.exe delete $PgService | Out-Null; Say "service $PgService" 'stopped and deleted' }
    if (Test-Path (Join-Path $PgData 'postmaster.pid')) { & "$PgBin\pg_ctl.exe" -D $PgData -m fast -w -t 300 stop 2>&1 | Out-Null }
    foreach ($d in @($PgData, $PgWal, $PgTemp)) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    Say 'drop' "$PgData$(if ($PgWal -ne "$PgData\pg_wal") { ", $PgWal" })$(if ($PgTemp) { ", $PgTemp" }) removed: cluster makes the cluster again"
}
# Settings: every setting stated (tune-pg.ps1); the server itself says which changed and which need a restart. A
# restart is never made under a running ingest.
function settings {
    Part 'settings'
    if (-not (PgReady)) { Say 'settings' 'FAILED: the server is not accepting connections (cluster first)'; $failed.Add('settings: server not ready'); return }
    if ((Test-Path $PgCanon) -and (Admin)) { $env:PGPASSFILE = $PgCanon }   # elevated: the canonical password, whatever the operator's pgpass holds
    try {
        Attempt 'settings' {
            TuneApply | ForEach-Object { Say '  ' $_ }
            if (-not (TuneRestart)) { if (-not (Admin)) { Say 'restart' 'a setting read at start is pending: elevated, setup.ps1 settings' } }
            if (-not (TuneCheck)) { throw 'the live server does not match the declaration (the warnings above)' }
            Say 'settings' "$((TuneDeclared).Count) declared, none pending"
        }
        foreach ($line in (TunePsql "SELECT '  '||rpad(name, 46)||current_setting(name) FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','io_method','max_wal_size','wal_buffers','listen_addresses','ssl') ORDER BY name")) { $line }
    } finally { Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue }
}
# Who may connect, and how (setup.sh: access). The whole pg_hba.conf, not a line added to whatever is there: laplace
# and postgres by scram on loopback, by scram over TLS from $PgLan, nothing else (no socket on Windows: no peer). The
# role's password is one canonical copy, administrators only, adopted from the operator's pgpass when it is the one
# the server accepts, made when none is, and written into the operator's %APPDATA%\postgresql\pgpass.conf, which libpq
# reads for psql and the laplace program. Only this host's line for the role is replaced there: the operator's lines
# for other hosts (hart-server's database) are theirs and stay. Never printed. The firewall admits the server's port (LAPLACE_PGPORT) from $PgLan.
function PgWorks([string]$pw) { $env:PGPASSWORD = $pw; $r = & "$PgBin\psql.exe" -X -h $PgHost -p $PgPort -U $PgRole -d postgres -Atq -c 'SELECT 1' 2>$null; Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue; "$r" -eq '1' }
function PgPassOf([string]$file) { if (Test-Path $file) { foreach ($l in Get-Content $file) { $f = $l -split ':'; if ($f.Count -ge 5 -and $f[3] -eq $PgRole -and $f[0] -in '*', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME) { return ($f[4..($f.Count - 1)] -join ':') } } }; $null }
function access {
    Part 'access'
    if (-not (Elevated 'access')) { return }
    if (-not (PgReady)) { Say 'access' 'FAILED: the server is not accepting connections (cluster first)'; $failed.Add('access: server not ready'); return }
    $operator = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
    Attempt "role $PgRole" {
        if ((PgSql "SELECT count(*) FROM pg_roles WHERE rolname = '$PgRole'") -ne '1') { PgSql "CREATE ROLE $PgRole LOGIN SUPERUSER" | Out-Null }
        $pw = PgPassOf $PgCanon; $how = "password in $PgCanon"
        # the installation's password is the deployment target's (LAPLACE_PEER): read from its operator's pgpass over SSH,
        # given to the role here when the role does not already accept it. Never printed.
        if ($env:LAPLACE_PEER) {
            $sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10'); if ($env:LAPLACE_PEER_KEY -and (Test-Path $env:LAPLACE_PEER_KEY)) { $sshOpts += '-i', $env:LAPLACE_PEER_KEY }
            $peer = (& ssh.exe @sshOpts $env:LAPLACE_PEER "grep ':${PgRole}:' ~/.pgpass | head -1 | cut -d: -f5-" 2>$null | Select-Object -First 1)
            if ($peer) {
                $peer = $peer.Trim()
                if (-not (PgWorks $peer)) { PgSql "ALTER ROLE $PgRole PASSWORD '$($peer -replace "'", "''")'" | Out-Null }
                $pw = $peer; $how = "password the installation's, from $($env:LAPLACE_PEER)"
                New-Item -ItemType Directory -Force (Split-Path $PgCanon) | Out-Null
                Set-Content -Path $PgCanon -Value "*:${PgPort}:*:${PgRole}:$pw" -Encoding ascii -NoNewline
                & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' /Q | Out-Null
            } else { Say "role $PgRole" "$($env:LAPLACE_PEER) did not answer with a password for ${PgRole}: this machine's own is kept" }
        }
        if (-not $pw -or -not (PgWorks $pw)) {
            $keep = $pw; $pw = $null
            $c = PgPassOf $operator; if ($c -and (PgWorks $c)) { $pw = $c; $how = "password adopted from $operator" }
            # a cluster made again has the role without a password: it is given the canonical one, so no client's copy breaks
            if (-not $pw -and $keep) { $pw = $keep; PgSql "ALTER ROLE $PgRole PASSWORD '$($pw -replace "'", "''")'" | Out-Null; $how = "password from $PgCanon" }
            if (-not $pw) { $pw = [Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Maximum 256 })) -replace '[/+=]', ''; $pw = $pw.Substring(0, [math]::Min(32, $pw.Length)); PgSql "ALTER ROLE $PgRole PASSWORD '$pw'" | Out-Null; $how = 'password made' }
            New-Item -ItemType Directory -Force (Split-Path $PgCanon) | Out-Null
            Set-Content -Path $PgCanon -Value "*:${PgPort}:*:${PgRole}:$pw" -Encoding ascii -NoNewline
            & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' /Q | Out-Null
        }
        # the operator's pgpass: this host's line for the role replaced, every other line kept
        New-Item -ItemType Directory -Force (Split-Path $operator) | Out-Null
        $rest = @(); if (Test-Path $operator) { $rest = @(Get-Content $operator | Where-Object { $f = $_ -split ':'; $f.Count -lt 5 -or $f[3] -ne $PgRole -or $f[0] -notin '*', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME }) }
        Set-Content -Path $operator -Value (@($rest) + "*:${PgPort}:*:${PgRole}:$pw") -Encoding ascii
        $pw = $null
        Say "role $PgRole" "$how; written to $operator"
    }
    Attempt 'role postgres' { if ((PgSql "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres'") -ne '1') { PgSql 'CREATE ROLE postgres LOGIN SUPERUSER' | Out-Null }; PgSql "ALTER ROLE postgres PASSWORD 'postgres'" | Out-Null; Say 'role postgres' "password postgres: locally and from $PgLan over TLS (setup.sh declares the same)" }
    Attempt 'pg_hba.conf' {
        $hba = @(
            "# Laplace (setup.ps1). Loopback: laplace and postgres by scram. The network: scram over TLS from $PgLan. Nothing else.",
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', $PgRole,    '127.0.0.1/32', 'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', $PgRole,    '::1/128',      'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostssl',   'all', $PgRole,    $PgLan,         'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', 'postgres', '127.0.0.1/32', 'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', 'postgres', '::1/128',      'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostssl',   'all', 'postgres', $PgLan,         'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostnossl', 'all', 'all',      '0.0.0.0/0',    'reject')
        ) -join "`n"
        $file = Join-Path $PgData 'pg_hba.conf'
        if ((Test-Path $file) -and ((Get-Content $file -Raw) -replace "`r`n", "`n").TrimEnd() -eq $hba) { Say 'pg_hba.conf' 'as declared'; return }
        if (Test-Path $file) { Copy-Item $file "$file.before" -Force }
        Set-Content -Path $file -Value ($hba + "`n") -Encoding ascii -NoNewline
        PgSql 'SELECT pg_reload_conf()' | Out-Null
        Say 'pg_hba.conf' 'written'
    }
    Attempt 'firewall' {
        # any enabled inbound allow rule for the server's port admits it already (an earlier install's rule counts); one is made only when none exists
        $have = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { ($_ | Get-NetFirewallPortFilter).LocalPort -contains $PgPort })
        if ($have.Count) { Say 'firewall' "$PgPort/tcp admitted by: $(($have | ForEach-Object DisplayName) -join ', ')" }
        else { New-NetFirewallRule -DisplayName 'Laplace PostgreSQL' -Direction Inbound -Protocol TCP -LocalPort $PgPort -RemoteAddress $PgLan -Action Allow -Profile Any | Out-Null; Say 'firewall' "$PgPort/tcp from $PgLan allowed" }
    }
    PgSql "SELECT '  '||rpad(type, 10)||rpad(array_to_string(user_name, ','), 10)||rpad(coalesce(address, '-'), 18)||auth_method||coalesce('   '||error, '') FROM pg_hba_file_rules ORDER BY rule_number"
}
# What the machine is now: the server, where it listens, and both legs of the cross-OS check, each as the operator
# with the operator's pgpass: this database from the network, and the database LAPLACE_CONNINFO names (hart-server's,
# when it is set to it).
function report {
    Part 'report'
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    Say "service $PgService" $(if ($svc) { "$($svc.Status), start $($svc.StartType)" } else { 'MISSING (cluster)' })
    if (-not (Test-Path "$PgBin\postgres.exe")) { Say 'server' "MISSING: no server at $PgBin (deps)"; return }
    Say 'server' "$(& "$PgBin\postgres.exe" --version)   $(if (PgReady) { 'accepting connections' } else { 'NOT ACCEPTING CONNECTIONS' })"
    if (-not (PgReady)) { return }
    $conn = "host=$PgHost port=$PgPort user=$PgRole dbname=postgres"
    Say 'PostGIS' "$(& "$PgBin\psql.exe" -X $conn -Atq -c "SELECT coalesce(default_version, 'NOT INSTALLED') FROM pg_available_extensions WHERE name = 'postgis'" 2>&1 | Select-Object -Last 1)"
    Say 'listening' ((Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress):$PgPort" } | Sort-Object -Unique) -join ' ')
    $net = ($PgLan -split '/')[0] -replace '\.\d+$', ''
    $addr = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$net.*" } | Select-Object -First 1).IPAddress
    if ($addr) {
        $r = & "$PgBin\psql.exe" -X "host=$addr port=$PgPort user=$PgRole dbname=postgres sslmode=require" -Atq -c "SELECT 'connected, TLS '||coalesce((SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'off')" 2>&1 | Select-Object -Last 1
        Say "this database from $PgLan, as $PgRole" "$r"
    } else { Say "this database from $PgLan" 'this machine has no address on it' }
    $r = & "$PgBin\psql.exe" -X ($env:LAPLACE_CONNINFO -replace 'dbname=\S+', 'dbname=postgres') -Atq -c "SELECT 'connected to '||coalesce(host(inet_server_addr()), 'local')||' ('||split_part(version(), ',', 1)||') as '||current_user||', TLS '||coalesce((SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'off')" 2>&1 | Select-Object -Last 1
    Say "LAPLACE_CONNINFO ($(($env:LAPLACE_CONNINFO -split ' ' | Where-Object { $_ -like 'host=*' }) -replace '^host='))" "$r"
    foreach ($line in (& "$PgBin\psql.exe" -X $conn -Atq -c "SELECT '  '||rpad(name, 46)||current_setting(name) FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','max_wal_size','listen_addresses','ssl','data_checksums') ORDER BY name" 2>$null)) { $line }
    ''; 'next: the Laplace builds (README: Windows); the Linux machine: sudo ./setup.sh, ./deploy.sh'
}

# ------------------------------------------------------------------------------------------------------ the desktop's own
# What this machine is besides a Laplace host: none of these is part of all, each is named to be run, and each takes
# status (setup.ps1 backup status) to report without changing anything.

# The deployment target's shares (setup.sh shares there), as this machine reaches them: by UNC path, with the
# operator's Credential Manager entry for the host. Checked and reported, never made: no drive letter is mapped and no
# credential is stored here, and the Explorer locations and mappings the operator made are theirs. A check that fails
# says what to do. The password is never read, printed or written: cmdkey asks for it.
function shares {
    Part 'shares'
    $server = $env:LAPLACE_SHARE_HOST; $user = $env:LAPLACE_SHARE_USER
    # cmdkey /list: a Target line, then Type and User; only this host's own entry counts (not hart-server.lan's)
    $entry = $null; $lines = @(& cmdkey.exe /list 2>$null)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*Target:\s*(Domain:target=)?$([regex]::Escape($server))\s*$") {
            $u = ($lines[($i + 1)..([math]::Min($i + 3, $lines.Count - 1))] | Where-Object { $_ -match '^\s*User:\s*(.+)$' } | Select-Object -First 1) -replace '^\s*User:\s*', ''
            $entry = "$($lines[$i].Trim() -replace '^Target:\s*', ''), user $u"; break
        }
    }
    if ($entry) { Say "credential for $server" "present: $entry" }
    else { Say "credential for $server" "MISSING: cmdkey /add:$server /user:$user /pass   (it asks for the SMB password)"; $failed.Add("shares: no credential for $server") }
    $tcp = [Net.Sockets.TcpClient]::new()
    try { $up = $tcp.ConnectAsync($server, 445).Wait(3000) } catch { $up = $false } finally { $tcp.Dispose() }
    if (-not $up) { Say "${server}:445" "DOES NOT ANSWER: is it up, and are its shares served (on $server, sudo ./setup.sh shares)?"; $failed.Add("shares: ${server}:445 does not answer"); return }
    Say "${server}:445" 'answers'
    foreach ($share in ($env:LAPLACE_SHARES -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
        $unc = "\\$server\$share"
        if (Test-Path -LiteralPath $unc) { Say $unc 'answers' }
        else {
            Say $unc "DOES NOT ANSWER: $(if ($entry) { "the credential may be wrong (cmdkey /delete:$server, then cmdkey /add:$server /user:$user /pass), or the share is not served (on $server, sudo ./setup.sh shares)" } else { 'add the credential (above)' })"
            $failed.Add("shares: $unc does not answer")
        }
    }
    if (Admin) { Say 'checked from' 'an elevated shell; Explorer uses the same credential from the normal one' }
}
# The GPU services (LAPLACE_GPU_SERVICES, llama.cpp under NSSM) are started, stopped and queried by the operator without
# elevation (chess\chess-gpu.ps1): one allow ACE for the operator's own SID (start RP, stop WP, query status LC,
# interrogate LO) appended to each service's DACL; nothing else in it changes. Already granted is known by the SID,
# never by the ACE's text, since Windows writes the rights in its own order. Each change prints the SDDL before and
# after; sc.exe sdset <service> "<before>" undoes it.
function services {
    Part 'services'
    if (-not $Status -and -not (Elevated 'services')) { return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent(); $sid = $me.User.Value
    foreach ($svc in ($env:LAPLACE_GPU_SERVICES -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
        Attempt "service $svc" {
            if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) { Say $svc 'NOT ON THIS MACHINE: nothing to grant'; return }
            $sd = ((& sc.exe sdshow $svc) -join '').Trim()
            if ($LASTEXITCODE) { throw "sc sdshow: $sd" }
            $held = @([regex]::Matches($sd, "\(A;;([A-Z]*);;;$([regex]::Escape($sid))\)") | ForEach-Object { $r = $_.Groups[1].Value; for ($k = 0; $k -lt $r.Length; $k += 2) { $r.Substring($k, 2) } })
            $lack = @('LC', 'RP', 'WP', 'LO' | Where-Object { $held -notcontains $_ })
            if (-not $lack.Count) { Say $svc "already granted to $($me.Name)"; return }
            if ($Status) { Say $svc "NOT GRANTED to $($me.Name) ($($lack -join '')): elevated, setup.ps1 services"; return }
            $i = $sd.IndexOf('S:'); $ace = "(A;;LCRPWPLO;;;$sid)"
            $new = if ($i -ge 0) { $sd.Insert($i, $ace) } else { $sd + $ace }
            $out = & sc.exe sdset $svc $new; if ($LASTEXITCODE) { throw "sc sdset: $($out -join ' ')" }
            Say $svc "granted to $($me.Name)"; "    before: $sd"; "    after:  $(((& sc.exe sdshow $svc) -join '').Trim())"
        }
    }
}
# The inbound rules this machine's endpoints need, each one named rule, TCP, from the one client that calls it
# (LAPLACE_FIREWALL: name=port@client;...): the engine endpoint (laplace-uci behind LaplaceEngines) for the deployment
# target. Created when missing, corrected when its port, client or profile differs, otherwise left alone.
function firewall {
    Part 'firewall'
    if (-not $Status -and -not (Elevated 'firewall')) { return }
    foreach ($spec in ($env:LAPLACE_FIREWALL -split ';' | ForEach-Object Trim | Where-Object { $_ })) {
        if ($spec -notmatch '^(?<name>[^=]+)=(?<port>\d+)@(?<client>[^@]+)$') { Say $spec 'UNREADABLE: name=port@client'; $failed.Add("firewall: $spec"); continue }
        $name = "Laplace-$($Matches.name)"; $port = $Matches.port; $client = $Matches.client
        Attempt "rule $name" {
            $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
            if (-not $r) {
                if ($Status) { Say $name "MISSING: TCP $port from $client (elevated, setup.ps1 firewall)"; return }
                New-NetFirewallRule -Name $name -DisplayName "Laplace $($Matches.name) $port from $client" -Direction Inbound -Protocol TCP `
                    -LocalPort $port -RemoteAddress $client -Action Allow -Profile Private | Out-Null
                Say $name "made: TCP $port from $client, private networks"; return
            }
            $p = $r | Get-NetFirewallPortFilter; $a = $r | Get-NetFirewallAddressFilter
            $ok = $r.Enabled -eq 'True' -and $r.Direction -eq 'Inbound' -and $r.Action -eq 'Allow' -and $p.Protocol -eq 'TCP' -and "$($p.LocalPort)" -eq $port `
                -and "$($a.RemoteAddress)" -eq $client -and "$($r.Profile)" -eq 'Private'
            if ($ok) { Say $name "as declared: TCP $port from $client"; return }
            if ($Status) { Say $name "DIFFERS (port $($p.LocalPort), from $($a.RemoteAddress), $($r.Profile)): elevated, setup.ps1 firewall"; return }
            Set-NetFirewallRule -Name $name -Enabled True -Direction Inbound -Action Allow -Profile Private
            $r | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $port
            $r | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $client
            Say $name "corrected: TCP $port from $client, private networks"
        }
    }
}
# The copy-off of this machine's drives to the deployment target (backup\: jobs.psd1 says what goes where; copyoff.ps1
# hashes and copies a set; run.ps1 runs every set), run by the scheduled task LAPLACE_BACKUP_TASK as the operator:
# interactive, not elevated, with no time limit, one instance at a time, no trigger (Start-ScheduledTask runs it), in a
# headless console. The task is registered when missing and updated when it differs from the declaration, but never
# while it runs: a running copy-off is not cut off, and the part says to run again when it is done. Then the state:
# the task, its run, the last job lines of each set's log and the manifests written.
function backup {
    Part 'backup'
    $task = $env:LAPLACE_BACKUP_TASK; $logs = $env:LAPLACE_BACKUP_LOGS
    $argv = "--headless pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $(Join-Path $PSScriptRoot 'backup\run.ps1')"
    $conf = $null
    try { $conf = Import-PowerShellDataFile $env:LAPLACE_BACKUP_JOBS }
    catch { Say 'jobs' "FAILED: $($env:LAPLACE_BACKUP_JOBS): $($_.Exception.Message)"; $failed.Add("backup: $($env:LAPLACE_BACKUP_JOBS) does not read") }
    foreach ($s in @($conf.Sets)) { $held = @($s.Jobs | Where-Object { $_.n -like 'Models-*' }).Count; Say "set $($s.Name)" "$(@($s.Jobs).Count) jobs to $($s.Inbox)$(if ($held) { "; $held Models-* on hold without -Models" })" }
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    $drift = @(
        if (-not $t) { 'missing' } else {
            $a = @($t.Actions)
            if ($a.Count -ne 1 -or $a[0].Execute -ne 'conhost.exe' -or $a[0].Arguments -ne $argv) { "runs $($a[0].Execute) $($a[0].Arguments)" }
            if ((($t.Principal.UserId -split '\\')[-1]) -ne $env:USERNAME) { "as $($t.Principal.UserId)" }
            if ("$($t.Principal.LogonType)" -ne 'Interactive') { "logon $($t.Principal.LogonType)" }
            if ("$($t.Principal.RunLevel)" -ne 'Limited') { "run level $($t.Principal.RunLevel)" }
            if ($t.Settings.ExecutionTimeLimit -ne 'PT0S') { "time limit $($t.Settings.ExecutionTimeLimit)" }
            if ("$($t.Settings.MultipleInstances)" -ne 'IgnoreNew') { "instances $($t.Settings.MultipleInstances)" }
            $trig = @($t.Triggers | Where-Object { $_ }); if ($trig.Count) { "$($trig.Count) trigger(s)" }
        })
    if (-not $drift.Count) { Say "task $task" 'as declared' }
    elseif ($Status) { Say "task $task" "DIFFERS: $($drift -join '; '): setup.ps1 backup" }
    elseif ($t -and "$($t.State)" -eq 'Running') { Say "task $task" "DIFFERS ($($drift -join '; ')), and it is running: not changed; setup.ps1 backup again when it is done" }
    else {
        Attempt "task $task" {
            New-Item -ItemType Directory -Force $logs | Out-Null
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $task -Action (New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argv) -Principal $principal -Settings $settings -Force | Out-Null
            Say "task $task" $(if ($t) { "updated (was: $($drift -join '; '))" } else { 'registered: Start-ScheduledTask runs it' })
        }
    }
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $task
        Say "task $task" $(if ($info.LastTaskResult -eq 0x41303) { "$($t.State); never run" } else { "{0}; last run {1:s}, result 0x{2:X}" -f $t.State, $info.LastRunTime, $info.LastTaskResult })
        Say 'runs' "$(@($t.Actions)[0].Execute) $(@($t.Actions)[0].Arguments)"
    }
    $pidFile = Join-Path $logs 'run.pid'
    if (Test-Path $pidFile) { $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue; Say 'run.pid' "$(Get-Content $pidFile)$(if ($p) { ", running since $('{0:s}' -f $p.StartTime)" } else { ', not running' })" }
    # the job lines of each set's log: neither progress, nor what could not be read, nor git's warnings
    foreach ($f in @(Get-ChildItem $logs -Filter 'run*.log' -File -ErrorAction SilentlyContinue)) {
        Say $f.Name ("{0:s}" -f $f.LastWriteTime)
        Get-Content $f.FullName | Where-Object { $_ -and $_ -notmatch '^\S+\s+[\d,]+/[\d,]+\s+\d+s$' -and $_ -notmatch 'unreadable|^warning:' } | Select-Object -Last 6 | ForEach-Object { "      $_" }
    }
    foreach ($s in @($conf.Sets)) {
        $dir = Join-Path $(if ($s.Logs) { Join-Path $logs $s.Logs } else { $logs }) 'manifests'
        foreach ($m in @(Get-ChildItem $dir -Filter '*.tsv' -File -ErrorAction SilentlyContinue)) { Say "manifest $($s.Name) $($m.BaseName)" "$((Get-Content $m.FullName -Tail 1) -replace '^# total ', '')   $('{0:s}' -f $m.LastWriteTime)" }
        foreach ($m in @(Get-ChildItem $dir -Filter '*.part' -File -ErrorAction SilentlyContinue)) { Say "manifest $($s.Name) $($m.Name)" "being written: $((Get-Content $m.FullName | Measure-Object -Line).Lines) rows" }
    }
}

$known = 'all', 'drop', 'volumes', 'packages', 'rights', 'deps', 'cluster', 'settings', 'access', 'report', 'shares', 'services', 'firewall', 'backup', 'status'
foreach ($p in $Parts) { if ($known -notcontains $p) { "setup.ps1 [drop] [$(($known | Select-Object -Skip 1) -join '|') ...]"; Stop-Transcript | Out-Null; exit 2 } }
# status: the desktop's own parts named with it (all three, when none is) report and change nothing
$Status = $Parts -contains 'status'
if ($Status) {
    $Parts = @($Parts | Where-Object { $_ -ne 'status' }); if (-not $Parts.Count) { $Parts = 'shares', 'services', 'firewall', 'backup' }
    $other = @($Parts | Where-Object { $_ -notin 'shares', 'services', 'firewall', 'backup' })
    if ($other.Count) { "setup.ps1 status reports shares, services, firewall and backup; $($other -join ', ') has none (report)"; Stop-Transcript | Out-Null; exit 2 }
}
try { foreach ($p in $Parts) { if ($p -eq 'all') { volumes; packages; rights; deps; cluster; settings; access; report } else { & $p } } }
catch { "=== $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"; $failed.Add("setup.ps1 stopped: $($_.Exception.Message)") }
''
if ($failed.Count) { '=== failed'; $failed | ForEach-Object { "  $_" } }
"=== done   {0:HH:mm:ss}   $log" -f (Get-Date).ToUniversalTime()
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
