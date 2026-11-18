#Requires -Version 7
<#
  Build Laplace on Windows: Laplace-Native once, installed as the CMake package LaplaceNative, then the extension and
  the engine against it (build.sh, native-package.sh).
    pwsh -File build.ps1            build both
    pwsh -File build.ps1 install    also install the extension into PostgreSQL's directories, by rename
  The builds run in the developer shell (LAPLACE_DEVSHELL) under the floating-point contract (toolchain\laplace.cmake,
  LAPLACE_MATH). A build tree keeps the flags it was configured with, so one made under another contract is made fresh.
#>
param([string]$Step = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
# the developer shell, unless it is already loaded: icx alone on the PATH is not it (laplace.env.ps1 puts oneAPI's bin
# there for the engine's run-time DLLs); the MSVC environment (vcvars sets VSCMD_VER) is what a link needs
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue)) -and (Test-Path $env:LAPLACE_DEVSHELL)) { . $env:LAPLACE_DEVSHELL *> $null }
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue))) { Write-Error "no developer shell: $env:LAPLACE_DEVSHELL (LAPLACE_DEVSHELL) must provide icx and the MSVC environment"; exit 1 }
$contract = ((Get-Content (Join-Path $PSScriptRoot 'toolchain\determinism.tsv') | Where-Object { $_ -match '^[a-z]' }) -join "`n")
$env:PATH = "$env:LAPLACE_PG_DIR\bin;$env:LAPLACE_ICU_DIR\bin64;$env:PATH"   # libpq and ICU, for the engine when it runs

# Laplace-Native once per source revision, installed as the CMake package LaplaceNative (native-package.ps1).
$nativePrefix = & "$PSScriptRoot\native-package.ps1" (Join-Path $env:LAPLACE_SRC 'Laplace-Native') | Select-Object -Last 1
if ($LASTEXITCODE) { exit $LASTEXITCODE }
$nativeConfig = Join-Path $nativePrefix 'lib\cmake\LaplaceNative'

foreach ($r in 'Laplace-postgres', 'Laplace-Engine') {
    $b = Join-Path (Join-Path $env:LAPLACE_BUILD $r) 'icx-release'; $mark = Join-Path $b '.contract'
    if ((Test-Path $b) -and -not ((Test-Path $mark) -and (Get-Content $mark -Raw) -eq $contract)) {
        "$r`: the build tree was configured under another contract: made fresh"; Remove-Item $b -Recurse -Force
    }
    & cmake.exe -S (Join-Path $env:LAPLACE_SRC $r) -B $b -G Ninja "-DCMAKE_TOOLCHAIN_FILE=$PSScriptRoot\toolchain\laplace.cmake" "-DLAPLACE_MATH=$env:LAPLACE_MATH" -DCMAKE_BUILD_TYPE=RelWithDebInfo "-DLaplaceNative_DIR=$nativeConfig"
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & cmake.exe --build $b
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Set-Content -Path $mark -Value $contract -NoNewline
}

if ($Step -eq 'install') {
    # Installed by rename, never by overwriting in place: a backend that has the old library mapped keeps the old file.
    # CMake stages the install under DESTDIR, dropping the drive letter; each file then moves into place.
    $stage = Join-Path $env:LAPLACE_WORK 'stage\extension'; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $env:DESTDIR = $stage
    try { & cmake.exe --install (Join-Path $env:LAPLACE_BUILD 'Laplace-postgres\icx-release') | Out-Null; if ($LASTEXITCODE) { exit $LASTEXITCODE } }
    finally { Remove-Item Env:DESTDIR -ErrorAction SilentlyContinue }
    $drive = Split-Path $env:LAPLACE_PG_DIR -Qualifier
    foreach ($f in Get-ChildItem $stage -Recurse -File) {
        $to = Join-Path $drive $f.FullName.Substring($stage.Length).TrimStart('\')
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        # a displaced file still mapped by a backend cannot be removed or renamed onto: each gets its own stale name, and
        # every stale one that can go, goes
        Get-ChildItem "$to.old*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        if (Test-Path $to) { Move-Item $to ("{0}.old-{1:yyyyMMddHHmmss}" -f $to, (Get-Date)) -Force }
        Move-Item $f.FullName $to -Force
        Get-ChildItem "$to.old*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    "extension installed into $env:LAPLACE_PG_DIR"
}
& (Join-Path $env:LAPLACE_BUILD 'Laplace-Engine\icx-release\laplace.exe') 2>&1 | Select-Object -Last 5
exit 0
