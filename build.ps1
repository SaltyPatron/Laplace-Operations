#Requires -Version 7
<#
  Build Laplace on Windows: the extension and the engine, each with Laplace-Native built as part of it. build.sh's
  counterpart: the same two builds, the same generator and build type, with icx from the developer shell
  (LAPLACE_DEVSHELL) under the floating-point contract.

    pwsh -File build.ps1            build both
    pwsh -File build.ps1 install    also install the extension into PostgreSQL's directories (LAPLACE_PG_DIR)

  Where everything is, is laplace.env.ps1's: the sources under LAPLACE_SRC, the builds under LAPLACE_BUILD.
#>
param([Parameter(Position = 0)][ValidateSet('', 'install')][string]$Do = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not (Test-Path $env:LAPLACE_DEVSHELL)) { throw "no developer shell at $env:LAPLACE_DEVSHELL (LAPLACE_DEVSHELL)" }
. $env:LAPLACE_DEVSHELL
if (-not (Get-Command icx.exe -ErrorAction SilentlyContinue)) { throw 'the developer shell gave no icx: setup.ps1 packages says what is missing' }
function Exec([string]$exe, [string[]]$arguments) { & $exe @arguments; if ($LASTEXITCODE) { throw "$exe $($arguments[0]) exited $LASTEXITCODE" } }

foreach ($r in 'Laplace-postgres', 'Laplace-Engine') {
    $src = Join-Path $env:LAPLACE_SRC $r; $b = Join-Path (Join-Path $env:LAPLACE_BUILD $r) 'icx-release'
    if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) { throw "no $r at $src (LAPLACE_SRC)" }
    Exec cmake.exe @('-S', $src, '-B', $b, '-G', 'Ninja', '-DCMAKE_C_COMPILER=icx', '-DCMAKE_CXX_COMPILER=icx', '-DCMAKE_BUILD_TYPE=RelWithDebInfo')
    Exec cmake.exe @('--build', $b)
}
if ($Do -eq 'install') { Exec cmake.exe @('--install', (Join-Path (Join-Path $env:LAPLACE_BUILD 'Laplace-postgres') 'icx-release')) }
$laplace = Join-Path (Join-Path (Join-Path $env:LAPLACE_BUILD 'Laplace-Engine') 'icx-release') 'laplace.exe'
& $laplace 2>&1 | Select-Object -Last 5
