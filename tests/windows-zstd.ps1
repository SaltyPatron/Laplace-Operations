#Requires -Version 7
[CmdletBinding()]
param([string]$Library, [string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
if (-not $Library) { $Library = Join-Path $env:LAPLACE_PG_DIR 'bin/zstd.dll' }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $env:LAPLACE_WORK 'verification/zstd' }
$Library = (Resolve-Path -LiteralPath $Library).Path
$null = New-Item -ItemType Directory -Force -Path $BuildDirectory
$BuildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path
$savedTemp = $env:TEMP; $savedTmp = $env:TMP
Push-Location $BuildDirectory
try {
    $env:TEMP = $BuildDirectory; $env:TMP = $BuildDirectory
    $exe = Join-Path $BuildDirectory 'zstd-roundtrip.exe'
    & icx /nologo /MD /Od (Join-Path $PSScriptRoot 'zstd-roundtrip.c') "/Fe:$exe"
    if ($LASTEXITCODE) { throw 'Zstd regression probe compilation failed.' }
    Write-Output "Zstd SHA256: $((Get-FileHash -LiteralPath $Library).Hash)"
    & $exe $Library $Library
    if ($LASTEXITCODE) { throw "Zstd byte-exact regression failed for $Library" }
} finally {
    $env:TEMP = $savedTemp; $env:TMP = $savedTmp
    Pop-Location
}
