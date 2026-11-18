#Requires -Version 7
<#
  Windows counterpart of package.sh: build one Laplace CMake repository once per source revision and dependency set,
  install it as its CMake package, and print the prefix (the last line of output).
    pwsh -File package.ps1 NAME SOURCE [VARIABLE=VALUE...]     each a CMake cache setting (-DVARIABLE=VALUE; written
    without the -D, which pwsh -File would split at a drive letter's colon)
  Prefix: $LAPLACE_BUILD\packages\NAME\<commit>[-<diff digest>][-<settings digest>], built in the developer shell under
  this Operations' floating-point contract (toolchain\laplace.cmake, LAPLACE_MATH); a complete prefix is reused; the
  three most recent of a NAME are kept.
#>
param([Parameter(Mandatory)][string]$PackageName, [Parameter(Mandatory)][string]$PackageSource,
      [Parameter(ValueFromRemainingArguments)][string[]]$PackageSettings = @())
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\laplace.env.ps1"
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue)) -and (Test-Path $env:LAPLACE_DEVSHELL)) { . $env:LAPLACE_DEVSHELL *> $null }
if (-not ($env:VSCMD_VER -and (Get-Command icx.exe -ErrorAction SilentlyContinue))) { Write-Error "no developer shell: $env:LAPLACE_DEVSHELL (LAPLACE_DEVSHELL) must provide icx and the MSVC environment"; exit 1 }
$PackageSource = (Resolve-Path $PackageSource).Path
$contract = ((Get-Content (Join-Path $PSScriptRoot 'toolchain\determinism.tsv') | Where-Object { $_ -match '^[a-z]' }) -join "`n")
function Get-ShortDigest([string]$text) {
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))).Substring(0, 12).ToLower()
}

$key = (& git -C $PackageSource rev-parse HEAD).Trim()
if (& git -C $PackageSource status --porcelain --untracked-files=no) { $key += '-' + (Get-ShortDigest ((& git -C $PackageSource diff HEAD) -join "`n")) }
if ($PackageSettings.Count) { $key += '-' + (Get-ShortDigest (($PackageSettings -join "`n") + "`n")) }
$packages = Join-Path $env:LAPLACE_BUILD "packages\$PackageName"; $prefix = Join-Path $packages $key
if (-not (Get-ChildItem (Join-Path $prefix 'lib\cmake\*\*Config.cmake') -ErrorAction SilentlyContinue)) {
    $build = Join-Path (Join-Path $env:LAPLACE_BUILD (Split-Path $PackageSource -Leaf)) 'package'; $mark = Join-Path $build '.contract'
    if ((Test-Path $build) -and -not ((Test-Path $mark) -and (Get-Content $mark -Raw) -eq $contract)) { Remove-Item $build -Recurse -Force }
    & cmake.exe -S $PackageSource -B $build -G Ninja "-DCMAKE_TOOLCHAIN_FILE=$PSScriptRoot\toolchain\laplace.cmake" "-DLAPLACE_MATH=$env:LAPLACE_MATH" -DCMAKE_BUILD_TYPE=RelWithDebInfo "-DLAPLACE_OPERATIONS=$PSScriptRoot" @($PackageSettings | ForEach-Object { "-D$_" }) | Write-Host
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
