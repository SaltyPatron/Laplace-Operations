#Requires -Version 7
<#
  Windows counterpart of native-package.sh: build Laplace-Native once per source revision and install it as the CMake
  package LaplaceNative; the last line of output is the prefix. Consumers configure with
  -DLaplaceNative_DIR=<prefix>\lib\cmake\LaplaceNative and compile none of Native.
    pwsh -File native-package.ps1 [native-source]     default $env:LAPLACE_SRC\Laplace-Native
  Prefix: $LAPLACE_BUILD\packages\laplace-native\<commit>[-<diff digest>], built in the developer shell under this
  Operations' floating-point contract (toolchain\laplace.cmake, LAPLACE_MATH); a complete prefix is reused; three kept.
#>
param([string]$Native = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue)) -and (Test-Path $env:LAPLACE_DEVSHELL)) { . $env:LAPLACE_DEVSHELL *> $null }
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue))) { Write-Error "no developer shell: $env:LAPLACE_DEVSHELL (LAPLACE_DEVSHELL) must provide icx and the MSVC environment"; exit 1 }
if (-not $Native) { $Native = Join-Path $env:LAPLACE_SRC 'Laplace-Native' }
$Native = (Resolve-Path $Native).Path
$contract = ((Get-Content (Join-Path $PSScriptRoot 'toolchain\determinism.tsv') | Where-Object { $_ -match '^[a-z]' }) -join "`n")

$key = (& git -C $Native rev-parse HEAD).Trim()
if (& git -C $Native status --porcelain --untracked-files=no) {
    $diff = (& git -C $Native diff HEAD) -join "`n"
    $key += '-' + ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diff)))).Substring(0, 12).ToLower()
}
$packages = Join-Path $env:LAPLACE_BUILD 'packages\laplace-native'; $prefix = Join-Path $packages $key
if (-not (Test-Path (Join-Path $prefix 'lib\cmake\LaplaceNative\LaplaceNativeConfig.cmake'))) {
    $build = Join-Path $env:LAPLACE_BUILD 'Laplace-Native\package'; $mark = Join-Path $build '.contract'
    if ((Test-Path $build) -and -not ((Test-Path $mark) -and (Get-Content $mark -Raw) -eq $contract)) { Remove-Item $build -Recurse -Force }
    & cmake.exe -S $Native -B $build -G Ninja "-DCMAKE_TOOLCHAIN_FILE=$PSScriptRoot\toolchain\laplace.cmake" "-DLAPLACE_MATH=$env:LAPLACE_MATH" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLAPLACE_NATIVE_TESTS=OFF "-DLAPLACE_OPERATIONS=$PSScriptRoot" | Write-Host
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & cmake.exe --build $build | Write-Host
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Set-Content -Path $mark -Value $contract -NoNewline
    Remove-Item "$prefix.partial" -Recurse -Force -ErrorAction SilentlyContinue
    & cmake.exe --install $build --prefix "$prefix.partial" | Out-Null
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Move-Item "$prefix.partial" $prefix
}
Get-ChildItem $packages -Directory | Where-Object { $_.Name -notlike '*.partial' } | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$prefix
