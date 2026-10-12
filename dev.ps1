#Requires -Version 7
[CmdletBinding()]
param(
    [ValidateSet('prepare','build','test')][string]$Operation = 'build',
    [string]$SourcePath
)
$ErrorActionPreference = 'Stop'
if ($SourcePath) { $env:LAPLACE_ROOT = [IO.Path]::GetFullPath($SourcePath) }
. "$PSScriptRoot/laplace.env.ps1"
if (-not $SourcePath) { $SourcePath = Join-Path $env:LAPLACE_SRC 'Laplace' }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
if (-not (Test-Path (Join-Path $SourcePath 'app/Laplace.slnx'))) { throw 'SourcePath must name the Laplace application checkout.' }
& pwsh -NoProfile -File "$PSScriptRoot/toolchain/windows/prepare-laplace.ps1" -LaplaceRoot $SourcePath
if ($LASTEXITCODE) { throw 'Development input preparation failed.' }
if ($Operation -eq 'prepare') { exit 0 }
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
    Run 'cmd.exe' @('/d','/c','scripts\win\build-engine.cmd','laplace_core','laplace_syzygy','laplace_dynamics','laplace_synthesis','laplace_t0_perfcache','laplace_highway_perfcache')
    $result.checks.native_build = 'passed'
    if ($Operation -eq 'build') {
        Run 'pwsh' @('-NoProfile','-File',(Join-Path $SourcePath 'scripts/win/publish-cli.ps1'))
        $result.checks.ingest_cli_publish = 'passed'
        $result.cli_path = $env:LAPLACE_CLI_EXE
        $result.cli_sha256 = (Get-FileHash -LiteralPath $env:LAPLACE_CLI_EXE -Algorithm SHA256).Hash.ToLowerInvariant()
        Run 'dotnet' @('build','app/Laplace.slnx','-c','Release','-p:Platform=Any CPU','--nologo')
        $result.checks.managed_build = 'passed'
        Push-Location web
        try {
            $lockHash = (Get-FileHash -LiteralPath package-lock.json -Algorithm SHA256).Hash
            $stamp = 'node_modules/.laplace-npm-ci.stamp'
            if (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $lockHash) {
                Run 'npm.cmd' @('ci','--no-audit','--no-fund')
                Set-Content -LiteralPath $stamp -Value $lockHash
            }
            Run 'npm.cmd' @('run','gen:api')
            Run 'npm.cmd' @('run','build')
            $result.checks.web_build = 'passed'
        } finally { Pop-Location }
    }
    Run 'dotnet' @('test','app/Laplace.Core.Tests/Laplace.Core.Tests.csproj','-c','Release','-p:Platform=AnyCPU','--nologo','--filter',
        'FullyQualifiedName~TextDecomposerTests|FullyQualifiedName~TrailingNewlineRoundtripTests|FullyQualifiedName~TrajectoryTests|FullyQualifiedName~NativeInteropTests')
    $result.checks.native_runtime = 'passed'
    $result.native_core_sha256 = (Get-FileHash -LiteralPath (Join-Path $env:LAPLACE_ENGINE_BUILD 'core/laplace_core.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    $result.dirty_source = [bool]@(& git -C $SourcePath status --porcelain --untracked-files=no)
    $result.status = 'passed'
} finally {
    Pop-Location
    $result.finished_utc = [DateTime]::UtcNow.ToString('o')
    [void](New-Item -ItemType Directory -Path (Split-Path $receipt) -Force)
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receipt
    Write-Host "Development evidence: $receipt"
}
