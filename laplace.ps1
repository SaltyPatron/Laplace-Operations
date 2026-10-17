#Requires -Version 7
<#
.SYNOPSIS
Operate the installed Laplace application through its delivery workflows.
.EXAMPLE
./laplace.ps1 verify -Target staging -Wait
.EXAMPLE
./laplace.ps1 deploy -Wait
.EXAMPLE
./laplace.ps1 db -Database substrate -DatabaseOperation recreate -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Operation = 'help',
    [ValidateSet('desktop','staging','production','cloud')][string]$Target,
    [ValidateSet('substrate','application','both')][string]$Database = 'both',
    [ValidateSet('status','migrate','repair','remigrate','recreate','reindex')][string]$DatabaseOperation = 'status',
    [string]$Revision = 'main',
    [string]$Repository = 'SaltyPatron/Laplace',
    [string]$SourcePath,
    [switch]$Yes,
    [switch]$Wait,
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments)][string[]]$RemainingArgs = @()
)
$ErrorActionPreference = 'Stop'
if ($Help -or $Operation -in @('help','-h','--help','/?') -or ($RemainingArgs | Where-Object { $_ -in @('help','-h','--help','/?') })) {
    $Operation = 'help'
} else {
    foreach ($token in $RemainingArgs) {
        switch ($token.ToLowerInvariant()) {
            { $_ -in @('--yes','-y','yes') } { $Yes = $true }
            { $_ -in @('--wait','-w','wait') } { $Wait = $true }
            { $_ -in @('desktop','staging','production','cloud') } {
                $Target = $_
                $PSBoundParameters['Target'] = $_
            }
            { $_ -in @('substrate','application','both','app') } {
                $Database = if ($_ -eq 'app') { 'application' } else { $_ }
            }
            { $_ -in @('status','migrate','repair','remigrate','recreate','reindex','up','reset','nuke') } {
                $DatabaseOperation = switch ($_) {
                    'up'    { 'migrate' }
                    'reset' { 'remigrate' }
                    'nuke'  { 'recreate' }
                    default { $_ }
                }
            }
            default {
                throw "Unrecognized argument '$token'. Run 'laplace-ops help' to see valid commands and options."
            }
        }
    }
}
$validOperations = @('help','status','runs','run','start','stop','logs','configure-development','enroll-development','verify','deploy','components','prepare','build','test','recovery','db','restart-iis')
if ($Operation -notin $validOperations) {
    throw "Unknown operation '$Operation'. Valid operations: $($validOperations -join ', ')"
}
if ($Operation -eq 'help') {
    @'
Laplace Operator & Developer CLI (laplace-ops)

LOCAL DESKTOP DEVELOPMENT (http://localhost:5187)
  laplace-ops prepare                 Fetch pinned Unicode/UCD and Tree-sitter grammar inputs
  laplace-ops build                   Build native C/C++ engine, ReadyToRun CLI, .NET solution, and web UI
  laplace-ops test                    Build native engine and run native/runtime interop tests
  laplace-ops run                     Run the local desktop API + web UI in the foreground
  laplace-ops start | stop | status   Manage the background local desktop server
  laplace-ops logs                    Tail logs from the active background local desktop server
  laplace-ops verify desktop          Verify the local desktop server (reuses running instance or cold-starts)

LOCAL DESKTOP IIS & DATABASE MAINTENANCE (https://dev.hartonomous.com)
  laplace-ops deploy desktop          Full desktop build + IIS publish + DB migrations + health check
  laplace-ops restart-iis             Cleanly recycle the local IIS site (app_offline.htm) and check /health
  laplace-ops db                      Check migration status for both local databases (application + substrate)
  laplace-ops db [both|application|substrate] [status|migrate|repair|remigrate|recreate] [-Yes]
    Examples:
      laplace-ops db                              Check status of both local databases
      laplace-ops db migrate                      Apply pending migrations + grants to both local databases
      laplace-ops db repair                       Recreate any dropped local database and apply migrations + grants
      laplace-ops db recreate -Yes                DROP and recreate both local databases from scratch
      laplace-ops db substrate recreate -Yes      DROP and recreate only the local substrate database (laplace-mono)
      laplace-ops db application recreate -Yes    DROP and recreate only the local app database (laplace-desktop-app)

LOCAL DESKTOP ONE-TIME SETUP & MODULAR CLI
  pwsh -File setup.ps1                Prepare dev inputs and register laplace-ops on PATH
  pwsh -File setup.ps1 all            Full Windows host setup (volumes, packages, deps, PostgreSQL, cluster, access)
  laplace-ops configure-development   Configure local Windows SSPI database roles and HBA rules
  laplace-ops enroll-development      Enroll Windows DPAPI workload credentials from OpenBao
  laplace-ops components desktop      Package Laplace-Native + Laplace-Engine and install the 'laplace' CLI

REMOTE CI/CD & ENVIRONMENT OPERATIONS (GitHub Actions)
  laplace-ops runs                    List recent GitHub Actions runs across all Laplace repositories
  laplace-ops status <staging|production> [-Wait]
  laplace-ops verify <staging|production> [-Wait]
  laplace-ops deploy <staging|production> [-Wait]
  laplace-ops db <staging|cloud> <substrate|application> <status|migrate|repair|recreate|reindex> [-Wait]
'@ | Write-Host
    exit 0
}
$desktopOperations = @('prepare','build','test','run','start','stop','logs','configure-development','enroll-development','db','restart-iis')
if (-not $PSBoundParameters.ContainsKey('Target')) {
    $Target = if ($Operation -in $desktopOperations) { 'desktop' } else { 'staging' }
}
if ($Operation -in @('prepare','build','test','run','start','stop','logs','configure-development','enroll-development','restart-iis') -and $Target -ne 'desktop') {
    throw "$Operation runs on desktop; target '$Target' is not supported. Use deploy to install a deployment target."
}
if ($Operation -eq 'db') {
    if ($Target -eq 'desktop') {
        if ($DatabaseOperation -eq 'reindex') { throw 'reindex is only supported for staging/cloud via db-ops.yml.' }
        . "$PSScriptRoot/laplace.env.ps1"
        $source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
        $iisConfig = if ($env:LAPLACE_IIS_INSTALLATION) { $env:LAPLACE_IIS_INSTALLATION } else { Join-Path $env:LAPLACE_DATA_ROOT 'services/laplace-mono-api/installation.json' }
        $scopes = if ($Database -eq 'both') { @('application','substrate') } else { @($Database) }
        if (Test-Path -LiteralPath $iisConfig) {
            $invokeDb = Join-Path $source 'deploy/windows/Invoke-IisDatabase.ps1'
            foreach ($scope in $scopes) {
                $dbArgs = @('-NoProfile','-File',$invokeDb,'-Installation',$iisConfig,'-Database',$scope,'-Operation',$DatabaseOperation)
                if ($Yes) { $dbArgs += '-Yes' }
                & pwsh @dbArgs
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
            exit 0
        }
        . (Join-Path $source 'scripts/win/laplace-paths.ps1')
        Import-LaplaceEnv
        $migrationsProject = Join-Path $source 'app/Laplace.Migrations/Laplace.Migrations.csproj'
        $migrationsDll = (& dotnet msbuild $migrationsProject -nologo -p:Configuration=Release -p:Platform=AnyCPU -getProperty:TargetPath).Trim()
        if (-not (Test-Path -LiteralPath $migrationsDll)) {
            throw "No IIS installation found at $iisConfig and Laplace.Migrations is not built yet. Run 'laplace-ops build' first."
        }
        if (-not $env:LAPLACE_APP_DB) {
            $appDbName = if ($env:LAPLACE_APP_DBNAME) { $env:LAPLACE_APP_DBNAME } else { 'laplace-desktop-app' }
            $env:LAPLACE_APP_DB = "Host=$env:LAPLACE_PGHOST;Port=$env:LAPLACE_PGPORT;Username=$env:LAPLACE_PGUSER;Database=$appDbName;Command Timeout=0"
        }
        foreach ($scope in $scopes) {
            $commands = switch ("$scope`:$DatabaseOperation") {
                'application:status'    { @(@('app-status'), @('app-check')) }
                'application:migrate'   { @(@('app-up'), @('app-check')) }
                'application:repair'    { @(@('app-up'), @('app-check')) }
                'application:remigrate' { if (-not $Yes) { throw 'Pass -Yes to remigrate.' }; @(@('app-reset','--yes'), @('app-up'), @('app-check')) }
                'application:recreate'  { if (-not $Yes) { throw 'Pass -Yes to recreate.' }; @(@('app-nuke','--yes'), @('app-check')) }
                'substrate:status'      { @(@('substrate-status')) }
                'substrate:migrate'     { @(@('substrate-up')) }
                'substrate:repair'      { @(@('substrate-up')) }
                'substrate:remigrate'   { if (-not $Yes) { throw 'Pass -Yes to remigrate.' }; @(@('reset','--yes'), @('substrate-up')) }
                'substrate:recreate'    { if (-not $Yes) { throw 'Pass -Yes to recreate.' }; @(@('nuke','--yes')) }
            }
            foreach ($cmd in $commands) {
                & dotnet $migrationsDll @cmd
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
        }
        exit 0
    }
    if ($Target -notin @('staging','production','cloud')) { throw "db supports desktop, staging, or cloud." }
    if ($Target -eq 'production') { throw 'Use -Target staging or cloud for remote database maintenance.' }
    if ($Database -eq 'both') { throw 'Remote database maintenance requires -Database substrate or -Database application.' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
    $dbInputs = @('-f',"target=$Target",'-f',"operation=$DatabaseOperation",'-f',"database=$Database")
    Write-Host "Dispatching db-ops.yml ($Database / $DatabaseOperation) on $Target from $Revision."
    $output = & gh workflow run 'db-ops.yml' --repo $Repository --ref $Revision @dbInputs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    $text = $output -join "`n"
    Write-Output $text
    if ($Wait -and $text -match '/actions/runs/(\d+)') {
        & gh run watch $Matches[1] --repo $Repository --exit-status --interval 10
        exit $LASTEXITCODE
    }
    exit 0
}
if ($Operation -eq 'restart-iis') {
    . "$PSScriptRoot/laplace.env.ps1"
    $source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
    & pwsh -NoProfile -File (Join-Path $source 'deploy/windows/Restart-IisApplication.ps1')
    exit $LASTEXITCODE
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
    if (-not $Installation) {
        $hostManifest = Join-Path $PSScriptRoot ('installation/' + $env:COMPUTERNAME.ToLowerInvariant() + '-modular-client.json')
        $Installation = if (Test-Path -LiteralPath $hostManifest) { $hostManifest } else { "$PSScriptRoot/installation/hart-desktop-modular-client.json" }
    }
    Write-Host "Packaging modular desktop stack (Laplace-Native, Laplace-Engine) and updating laplace CLI..."
    & pwsh -NoProfile -File "$PSScriptRoot/installation/install-windows-client.ps1" -Installation $Installation
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
