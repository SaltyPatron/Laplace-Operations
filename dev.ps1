#Requires -Version 7
[CmdletBinding()]
param(
    [ValidateSet('prepare','build','test')][string]$Operation = 'build',
    [string]$SourcePath,[string]$Components='all',[switch]$Force
)
$ErrorActionPreference = 'Stop'
if ($SourcePath) { $env:LAPLACE_ROOT = [IO.Path]::GetFullPath($SourcePath) }
. "$PSScriptRoot/laplace.env.ps1"
if (-not $SourcePath) { $SourcePath = Join-Path $env:LAPLACE_SRC 'Laplace' }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
if (-not (Test-Path (Join-Path $SourcePath 'app/Laplace.slnx'))) { throw 'SourcePath must name the Laplace application checkout.' }
if ($Operation -eq 'prepare') {
    & pwsh -NoProfile -File "$PSScriptRoot/toolchain/windows/prepare-laplace.ps1" -LaplaceRoot $SourcePath
    if ($LASTEXITCODE) { throw 'Development input preparation failed.' }
    exit 0
}
. "$PSScriptRoot/toolchain/windows/devshell.ps1"
. (Join-Path $SourcePath 'scripts/win/laplace-paths.ps1')
Import-LaplaceEnv
function Run([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE) { throw "$Program failed with exit code $LASTEXITCODE" }
}
$began = [DateTime]::UtcNow
$receipt = Join-Path $env:LAPLACE_WORK ('operations/development-' + $began.ToString('yyyyMMdd-HHmmss') + '.json')
$result = [ordered]@{operation=$Operation; source=$SourcePath; revision=(& git -C $SourcePath rev-parse HEAD); build_root=$env:LAPLACE_BUILD_ROOT; started_utc=$began.ToString('o'); status='failed'; checks=@{}}
Push-Location $SourcePath
try {
    if ($Operation -eq 'build') {
        $componentsReceipt=Join-Path $env:LAPLACE_BUILD_ROOT 'desktop-artifacts.json'
        $arguments=@('-NoProfile','-File',(Join-Path $SourcePath 'deploy/windows/Build-IisPackage.ps1'),'-ComponentSelection',$Components,'-Receipt',$componentsReceipt)
        if($Force){$arguments+='-Force'}
        Run 'pwsh' $arguments
        $result.components=Get-Content -LiteralPath $componentsReceipt -Raw|ConvertFrom-Json
        $result.cli_path=Join-Path $result.components.package 'cli/Laplace.Cli.exe'
        $result.cli_sha256=(Get-FileHash -LiteralPath $result.cli_path).Hash.ToLowerInvariant()
        $result.checks.component_build='passed'
    }else{
        Run 'cmd.exe' @('/d','/c','scripts\win\build-engine.cmd','laplace_core','laplace_syzygy','laplace_dynamics','laplace_synthesis','laplace_t0_perfcache','laplace_highway_perfcache')
        $result.checks.native_build='passed'
    }
    if($Operation -eq 'test'){
    Run 'dotnet' @('test','app/Laplace.Core.Tests/Laplace.Core.Tests.csproj','-c','Release','-p:Platform=AnyCPU','--nologo','--filter',
        'FullyQualifiedName~TextDecomposerTests|FullyQualifiedName~TrailingNewlineRoundtripTests|FullyQualifiedName~TrajectoryTests|FullyQualifiedName~NativeInteropTests')
    $result.checks.native_runtime = 'passed'
    }
    $corePath=if($Operation -eq 'build'){Join-Path $result.components.package 'laplace_core.dll'}else{Join-Path $env:LAPLACE_ENGINE_BUILD 'core/laplace_core.dll'}
    $result.native_core_sha256 = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result.dirty_source = [bool]@(& git -C $SourcePath status --porcelain --untracked-files=no)
    $result.status = 'passed'
} finally {
    Pop-Location
    $result.finished_utc = [DateTime]::UtcNow.ToString('o')
    [void](New-Item -ItemType Directory -Path (Split-Path $receipt) -Force)
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receipt
    Write-Host "Development evidence: $receipt"
    . "$PSScriptRoot/installation/storage.ps1"
    try{Invoke-OperationHistoryCleanup}catch{if($result.status -eq 'passed'){throw};Write-Warning "History cleanup failed: $_"}
}
