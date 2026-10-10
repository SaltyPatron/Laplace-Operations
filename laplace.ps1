#Requires -Version 7
<#
.SYNOPSIS
Operate the installed Laplace application through its delivery workflows.
.EXAMPLE
./laplace.ps1 verify -Target staging -Wait
.EXAMPLE
./laplace.ps1 deploy -Wait
#>
[CmdletBinding()]
param(
    [ValidateSet('status','runs','verify','deploy','prepare','build','test')][string]$Operation = 'status',
    [ValidateSet('staging','production','knowledge')][string]$Target = 'staging',
    [string]$Revision = 'main',
    [string]$Repository = 'SaltyPatron/Laplace',
    [string]$SourcePath,
    [switch]$Wait
)
$ErrorActionPreference = 'Stop'
if ($Operation -in 'prepare','build','test') {
    $localArgs = @('-NoProfile','-File',"$PSScriptRoot/dev.ps1",'-Operation',$Operation)
    if ($SourcePath) { $localArgs += @('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
if ($Operation -eq 'runs') {
    & gh run list --repo $Repository --limit 12
    exit $LASTEXITCODE
}
if ($Operation -eq 'deploy') {
    Write-Host "Deploy ${Revision}: staging verification, cloud build, production verification."
} else {
    Write-Host "$Operation on $Target using checks from $Revision."
}
$output = & gh workflow run product-operator.yml --repo $Repository --ref $Revision -f "operation=$Operation" -f "target=$Target" 2>&1
if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
$text = $output -join "`n"
Write-Output $text
if ($Wait) {
    if ($text -notmatch '/actions/runs/(\d+)') {
        throw 'GitHub accepted the operation but did not return its run ID. Use ./laplace.ps1 runs to follow it.'
    }
    $runId = $Matches[1]
    & gh run watch $runId --repo $Repository --exit-status --interval 10
    $operationExit = $LASTEXITCODE
    if ($Operation -in 'status','verify') {
        . "$PSScriptRoot/laplace.env.ps1"
        $evidence = Join-Path $env:LAPLACE_WORK "operations/$runId"
        [void](New-Item -ItemType Directory -Path $evidence -Force)
        & gh run download $runId --repo $Repository --name "application-verification-$Target-$runId" --dir $evidence
        if ($LASTEXITCODE -ne 0) { throw "Cannot retrieve the operation evidence for $runId" }
        Write-Host "Saved installed status and verification: $evidence"
        $receipt = Join-Path $evidence 'application-verification.json'
        if (Test-Path -LiteralPath $receipt) { Get-Content -LiteralPath $receipt }
    }
    exit $operationExit
}
