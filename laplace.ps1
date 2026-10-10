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
    [ValidateSet('status','verify','deploy')][string]$Operation = 'status',
    [ValidateSet('staging','production','knowledge')][string]$Target = 'staging',
    [string]$Revision = 'main',
    [string]$Repository = 'SaltyPatron/Laplace',
    [switch]$Wait
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
if ($Operation -eq 'status') {
    & gh run list --repo $Repository --limit 12
    exit $LASTEXITCODE
}
if ($Operation -eq 'deploy') {
    Write-Host "Deploy ${Revision}: staging verification, cloud build, production verification."
} else {
    Write-Host "Verify the installed application on $Target using checks from $Revision."
}
$output = & gh workflow run product-operator.yml --repo $Repository --ref $Revision -f "operation=$Operation" -f "target=$Target" 2>&1
if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
$text = $output -join "`n"
Write-Output $text
if ($Wait) {
    if ($text -notmatch '/actions/runs/(\d+)') {
        throw 'GitHub accepted the operation but did not return its run ID. Use ./laplace.ps1 status to follow it.'
    }
    & gh run watch $Matches[1] --repo $Repository --exit-status
    exit $LASTEXITCODE
}
