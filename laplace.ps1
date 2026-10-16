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
    [ValidateSet('status','runs','run','start','stop','logs','configure-development','enroll-development','verify','deploy','components','prepare','build','test','recovery')][string]$Operation = 'status',
    [ValidateSet('desktop','staging','production','cloud')][string]$Target,
    [string]$Revision = 'main',
    [string]$Repository = 'SaltyPatron/Laplace',
    [string]$SourcePath,
    [switch]$Wait
)
$ErrorActionPreference = 'Stop'
$desktopOperations = @('prepare','build','test','run','start','stop','logs','configure-development','enroll-development')
if (-not $PSBoundParameters.ContainsKey('Target')) {
    $Target = if ($Operation -in $desktopOperations) { 'desktop' } else { 'staging' }
}
if ($Operation -in $desktopOperations -and $Target -ne 'desktop') {
    throw "$Operation runs on desktop; target '$Target' is not supported. Use deploy to install a deployment target."
}
if ($Operation -eq 'deploy' -and $Target -eq 'desktop') {
    . "$PSScriptRoot/laplace.env.ps1"
    $source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
    Write-Host "Deploying desktop IIS package (https://dev.hartonomous.com) and migrating local databases from $source..."
    & pwsh -NoProfile -File (Join-Path $source 'deploy/windows/Build-IisPackage.ps1') -Publish
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & pwsh -NoProfile -File (Join-Path $source 'deploy/windows/Invoke-IisDatabase.ps1') -Database application -Operation migrate
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & pwsh -NoProfile -File (Join-Path $source 'deploy/windows/Invoke-IisDatabase.ps1') -Database substrate -Operation migrate
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & pwsh -NoProfile -File "$PSScriptRoot/installation/Verify-DesktopDatabases.ps1"
    exit $LASTEXITCODE
}
if ($Operation -eq 'components' -and $Target -eq 'desktop') {
    Write-Host "Packaging modular desktop stack (Laplace-Native, Laplace-Engine) and updating laplace CLI..."
    & pwsh -NoProfile -File "$PSScriptRoot/installation/install-windows-client.ps1" -Installation "$PSScriptRoot/installation/hart-desktop-modular-client.json"
    exit $LASTEXITCODE
}
if ($Operation -eq 'deploy' -and $Target -notin @('staging','production')) {
    throw 'deploy supports desktop, staging, or production. Use components -Target cloud for on-demand component qualification.'
}
if ($SourcePath -and $Target -ne 'desktop') {
    throw 'SourcePath selects local desktop sources; remote operations use Revision.'
}
if ($Operation -in 'start','stop','logs' -or ($Operation -in 'status','verify' -and $Target -eq 'desktop')) {
    if ($PSBoundParameters.ContainsKey('Target') -and $Target -ne 'desktop') { throw "$Operation is a desktop lifecycle operation; use the deployment operator for another target." }
    $localArgs=@('-NoProfile','-File',"$PSScriptRoot/development/control.ps1",'-Operation',$Operation)
    if ($SourcePath) { $localArgs+=@('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if ($Operation -eq 'enroll-development') {
    & pwsh -NoProfile -File "$PSScriptRoot/development/enroll.ps1"
    exit $LASTEXITCODE
}
if ($Operation -eq 'configure-development') {
    & pwsh -NoProfile -File "$PSScriptRoot/development/configure.ps1"
    exit $LASTEXITCODE
}
if ($Operation -eq 'run') {
    if ($Operation -eq 'run' -and $PSBoundParameters.ContainsKey('Target') -and $Target -ne 'desktop') {
        throw 'run starts the desktop development process; use deploy for a deployment target.'
    }
    $localArgs = @('-NoProfile','-File',"$PSScriptRoot/development/run.ps1")
    if ($SourcePath) { $localArgs += @('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if ($Operation -in 'prepare','build','test') {
    $localArgs = @('-NoProfile','-File',"$PSScriptRoot/dev.ps1",'-Operation',$Operation)
    if ($SourcePath) { $localArgs += @('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if ($Target -eq 'desktop') { throw 'Desktop supports prepare, build, test, start, stop, status, logs, run and verify.' }
if ($Operation -eq 'recovery') {
    & pwsh -NoProfile -File "$PSScriptRoot/backup/recovery.ps1" -Target $Target
    exit $LASTEXITCODE
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
if ($Operation -eq 'runs') {
    if ($PSBoundParameters.ContainsKey('Repository')) {
        & gh run list --repo $Repository --limit 12
        exit $LASTEXITCODE
    }
    foreach ($repo in @('SaltyPatron/Laplace','SaltyPatron/Laplace-Operations','SaltyPatron/Laplace-Native','SaltyPatron/Laplace-postgres','SaltyPatron/Laplace-Engine','SaltyPatron/Laplace-MCP')) {
        Write-Host "=== $repo ===" -ForegroundColor Cyan
        & gh run list --repo $repo --limit 4
    }
    exit 0
}
$workflow = 'product-operator.yml'
$inputs = @('-f',"operation=$Operation",'-f',"target=$Target")
if ($Operation -eq 'components') {
    if ($Target -eq 'production') { throw 'Use deploy for public production delivery; components supports staging and on-demand cloud-host verification.' }
    if (-not $PSBoundParameters.ContainsKey('Repository')) { $Repository = 'SaltyPatron/Laplace-Operations' }
    $workflow = 'laplace.yml'
    $inputs = @('-f','drop=false','-f','reseed=false','-f',"cloud=$($Target -eq 'cloud')".ToLowerInvariant())
    Write-Host "Verify component deployment from $Revision on $Target."
} elseif ($Operation -eq 'deploy') {
    if ($Target -eq 'production') {
        Write-Host "Deploy ${Revision}: staging verification, package transfer, production verification."
    } else {
        Write-Host "Deploy ${Revision} to staging on hart-server."
    }
} else {
    Write-Host "$Operation on $Target using checks from $Revision."
}
$output = & gh workflow run $workflow --repo $Repository --ref $Revision @inputs 2>&1
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
