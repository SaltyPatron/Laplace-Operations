#Requires -Version 7
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$Installation,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$RunId)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
$work=Join-Path $env:LAPLACE_WORK "operations/desktop-run-$RunId"
try {
    & "$PSScriptRoot/run.ps1" -SourcePath $SourcePath -Installation $Installation -RunId $RunId *> "$work/launcher.log"
} catch {
    $_ | Out-String | Add-Content -LiteralPath "$work/launcher.log"
    exit 1
}
