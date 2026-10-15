#Requires -Version 7
[CmdletBinding()]
param([string]$Library, [string]$BuildDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
if(-not $Library){$Library=if($env:LAPLACE_LZ4_TEST_DLL){$env:LAPLACE_LZ4_TEST_DLL}else{Join-Path $env:LAPLACE_PG_DIR 'bin/lz4.dll'}}
if(-not $BuildDirectory){$BuildDirectory=Join-Path $env:LAPLACE_WORK ('verification/lz4-'+[guid]::NewGuid().ToString('N'))}
$null=New-Item -ItemType Directory -Force -Path $BuildDirectory
$savedTemp=$env:TEMP; $savedTmp=$env:TMP
Push-Location $BuildDirectory
try {
    $env:TEMP=$BuildDirectory; $env:TMP=$BuildDirectory
    $exe=Join-Path $BuildDirectory 'lz4-roundtrip.exe'
    & icx /nologo /MD /Od (Join-Path $PSScriptRoot 'lz4-roundtrip.c') "/Fe:$exe"
    if($LASTEXITCODE){throw 'LZ4 regression probe compilation failed.'}
    Write-Output "LZ4 SHA256: $((Get-FileHash -LiteralPath $Library).Hash)"
    & $exe $Library $Library (Join-Path $PSScriptRoot 'lz4-index-expression.txt')
    if($LASTEXITCODE){throw "LZ4 byte-exact regression failed for $Library"}
} finally { $env:TEMP=$savedTemp; $env:TMP=$savedTmp; Pop-Location }
