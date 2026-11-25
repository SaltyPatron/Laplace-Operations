#Requires -Version 7
<# The desktop deployment behind laplace-ops. Setup owns provisioning; this
   workflow converges tuning on the existing installation and records every delivery stage. #>
[CmdletBinding()]
param([string]$SourcePath, [string]$ModularInstallation, [switch]$Plan,
    [string]$Components='all',[switch]$Force,[string]$Package,[switch]$AsIs)
$ErrorActionPreference = 'Stop'
$operations = Split-Path -Parent $PSScriptRoot
. "$operations/laplace.env.ps1"
$source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }

# Never from old sources, as deploy.sh: every checkout this builds from (Operations, Native, postgres, Engine, MCP, the
# application) is brought to its upstream first. The desktop built whatever its sibling checkouts held, so a
# Laplace-postgres days behind installed an extension older than the Engine and the application expected. A checkout on
# no branch is an exact revision someone chose and is left as it is; one with changed tracked files, commits of its own,
# or an upstream that cannot be fetched stops the deployment before anything is built. -AsIs deploys what is here.
if (-not $Plan -and -not $Package -and -not $AsIs -and -not $env:LAPLACE_DEPLOY_CURRENT) {
    $moved = $false
    $checkouts = [ordered]@{ 'Laplace-Operations'=$operations; 'Laplace'=$source }
    foreach ($name in 'Laplace-Native','Laplace-postgres','Laplace-Engine','Laplace-MCP') { $checkouts[$name] = Join-Path $env:LAPLACE_SRC $name }
    foreach ($entry in $checkouts.GetEnumerator()) {
        $name = $entry.Key; $path = $entry.Value
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { throw "$path is not a git checkout: nothing says what revision it is (-AsIs deploys it anyway)" }
        $git = @('-c',"safe.directory=$path",'-C',$path)
        $branch = & git @git symbolic-ref -q --short HEAD
        if ($LASTEXITCODE) { Write-Host "  ${name}: at $((& git @git rev-parse --short=12 HEAD)), on no branch: an exact revision, left as it is"; continue }
        $null = & git @git rev-parse -q --verify '@{upstream}' 2>$null
        if ($LASTEXITCODE) { throw "${path}: $branch follows no upstream (-AsIs deploys it anyway)" }
        $changed = @(& git @git status --porcelain --untracked-files=no)
        if ($changed.Count) { throw "$path has changed files:`n$($changed | Select-Object -First 10 | Out-String)commit or drop them, or deploy -AsIs" }
        $was = (& git @git rev-parse HEAD).Trim()
        & git @git fetch -q; if ($LASTEXITCODE) { throw "${path}: its upstream could not be fetched, so whether it is current is not known (-AsIs deploys it anyway)" }
        & git @git merge -q --ff-only '@{upstream}'; if ($LASTEXITCODE) { throw "${path}: $branch has commits its upstream does not (-AsIs deploys it anyway)" }
        $now = (& git @git rev-parse HEAD).Trim()
        if ($was -eq $now) { Write-Host "  ${name}: at its upstream, $($now.Substring(0,12)) ($branch)" }
        else { Write-Host "  ${name}: brought from $($was.Substring(0,12)) to $($now.Substring(0,12)) ($branch)"; if ($name -eq 'Laplace-Operations') { $moved = $true } }
    }
    if ($moved) {
        Write-Host '  this script changed: running what arrived'
        $env:LAPLACE_DEPLOY_CURRENT = '1'
        # Arguments spelled out: splatting the bound parameters into a native pwsh call passes an empty string as a
        # bare "-Name:" token, which shifts every argument after it.
        $again = @()
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Value -is [System.Management.Automation.SwitchParameter]) { if ($entry.Value.IsPresent) { $again += '-' + $entry.Key } }
            elseif ("$($entry.Value)") { $again += @('-' + $entry.Key, [string]$entry.Value) }
        }
        & pwsh -NoProfile -File $PSCommandPath @again
        exit $LASTEXITCODE
    }
} elseif ($AsIs) { Write-Host '  deploying what is here, not checked against any upstream (-AsIs)' }
$installation = $env:LAPLACE_IIS_INSTALLATION
. "$PSScriptRoot/desktop-clients.ps1"
if (-not $ModularInstallation) { $ModularInstallation=Join-Path $PSScriptRoot ($env:COMPUTERNAME.ToLowerInvariant()+'-modular-client.json') }
$selected=[Collections.Generic.HashSet[string]]::new([string[]]$Components.Split(','),[StringComparer]::Ordinal)
if($Package){
    if($Components -ne 'all' -or $Force){throw 'A prepared package is already composed; do not combine -Package with -Components or -Force.'}
    $Package=[IO.Path]::GetFullPath($Package)
    $selected=[Collections.Generic.HashSet[string]]::new([string[]]@('api','cli','uci','web'),[StringComparer]::Ordinal)
}
$valid=@('all','modular','modular-web','native','postgres','api','cli','uci','migrations','web')
if(@($selected | Where-Object {$_ -notin $valid}).Count){throw "Unknown component selection: $Components"}
if($selected.Contains('modular-web')){throw 'modular-web (Laplace-MCP/web) is retired; deploy the unified product UI with -Components web (or all).'}
if($selected.Contains('all')){foreach($name in $valid | Where-Object {$_ -notin @('all','modular-web')}){$null=$selected.Add($name)};$null=$selected.Remove('all')}
if($selected.Contains('native')){foreach($name in $valid | Where-Object {$_ -notin @('all','modular-web')}){$null=$selected.Add($name)}}
if($selected.Contains('postgres')){foreach($name in 'native','api','cli','uci','migrations','web'){$null=$selected.Add($name)}}
if($selected.Contains('api')){$null=$selected.Add('web')}
$mono=@($selected | Where-Object {$_ -notin @('modular','modular-web')} | Sort-Object)
$modular=if($selected.Contains('modular') -or $selected.Contains('modular-web')){Get-DesktopClientDeclaration $ModularInstallation}else{$null}
$scope=if($modular){if($mono.Count){'all'}else{'modular'}}else{'monorepo'}
$steps=@()
if($selected.Contains('postgres')){$steps+=@{name='Apply and verify PostgreSQL tuning';script="$operations/tune-pg.ps1";arguments=@();inputs=@('Laplace-Operations')}}
if($mono.Count){
    if($Package){
        $steps+=@{name='Activate verified prepared IIS package';script="$source/deploy/windows/Publish-IisRuntime.ps1";arguments=@('-Package',$Package)}
    }else{
        $arguments=@('-Publish','-ComponentSelection',($mono -join ','))
        if($Force){$arguments+='-Force'}
        $steps+=@{name='Build selected components, compose and activate IIS';script="$source/deploy/windows/Build-IisPackage.ps1";arguments=$arguments;component_receipt=$true;inputs=@('Laplace','Laplace-Native','Laplace-postgres','Laplace-Engine','Laplace-Operations')}
    }
}
if($selected.Contains('modular')){
    $arguments=@('-Installation',$ModularInstallation,'-ConfigureDatabase');if($Force){$arguments+='-Force'}
    $steps+=@{name='Package modular Native, Engine and MCP; update installed client';script="$PSScriptRoot/install-windows-client.ps1";arguments=$arguments;inputs=@('Laplace-Native','Laplace-postgres','Laplace-Engine','Laplace-MCP','Laplace-Operations')}
}
if($selected.Contains('modular')){
    # deploy-client.py: laplace deploy --configure-server-cache, then the modular browser's read grants. A changed
    # extension recreates the database (no upgrade path), and a recreated database holds no grant for
    # laplace_modular_web until they are given again; Linux grants in the same step (deploy.sh modular-grants).
    $steps+=@{name='Migrate the installed modular substrate, select server-local caches and grant its readers';command='py';arguments=@('-3',"$PSScriptRoot/deploy-client.py",'--configuration',$modular.operator_client.configuration,'--psql',(Join-Path $env:LAPLACE_PG_DIR 'bin/psql.exe'));inputs=@('Laplace-Native','Laplace-postgres','Laplace-Engine','Laplace-MCP','Laplace-Operations')}
}
if($selected.Contains('uci')){
    $steps+=@{name='Publish the desktop UCI connector and bind its engine to the selected local substrate';script="$PSScriptRoot/desktop-uci.ps1";arguments=@('-IisInstallation',$installation,'-Publish');inputs=@('Laplace','Laplace-Operations')}
}
if($selected.Contains('modular-web')){
    $steps+=@{name='Publish and verify the modular browser';script="$PSScriptRoot/Publish-ModularWeb.ps1";arguments=@();inputs=@('Laplace-MCP','Laplace-Native','Laplace-Engine','Laplace-Operations')}
}
$steps+=@{name='Verify selected installed components';script="$PSScriptRoot/Verify-DesktopDatabases.ps1";arguments=@('-ModularInstallation',$ModularInstallation,'-Scope',$scope)}
Write-Host 'Laplace desktop deployment' -ForegroundColor Cyan
Write-Host "Source: $source"
Write-Host "Installation: $installation"
Write-Host ('Components: '+(@($selected | Sort-Object) -join ', '))
if ($Plan) {
    for ($i=0; $i -lt $steps.Count; $i++) {
        Write-Host "[$($i+1)/$($steps.Count)] $($steps[$i].name)"
        $invocation=if($steps[$i].command){'"'+$steps[$i].command+'"'}else{'pwsh -NoProfile -File "'+$steps[$i].script+'"'}
        Write-Host ('  '+$invocation+' '+($steps[$i].arguments -join ' '))
    }
    Write-Host 'Plan only. Installation access and live checks have not run.'
    exit 0
}

# A step's result is identified by the content of its inputs: the revision of every checkout it reads and any
# uncommitted change in them, its arguments, and its own name. A step whose inputs are the ones of its last passing
# run has nothing to produce, and is not run again (-Force runs every step). The installation's verification has no
# declared inputs and always runs, so a skipped step's output is still checked.
function Get-StepDigest($step) {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("step=$($step.name)"); $parts.Add("arguments=$($step.arguments -join "`u{1f}")")
    foreach ($repo in $step.inputs) {
        $path = switch ($repo) { 'Laplace-Operations' { $operations } 'Laplace' { $source } default { Join-Path $env:LAPLACE_SRC $repo } }
        $git = @('-c',"safe.directory=$path",'-C',$path)
        $head = (& git @git rev-parse HEAD 2>$null); if ($LASTEXITCODE) { return $null }
        $parts.Add("$repo=$("$head".Trim())")
        $diff = (& git @git diff HEAD --no-ext-diff --binary 2>$null) -join "`n"
        if ($diff) { $parts.Add("$repo-uncommitted=$diff") }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
$digestsPath = Join-Path $env:LAPLACE_WORK 'operations/desktop-step-digests.json'
$digests = @{}
if (Test-Path -LiteralPath $digestsPath) { (Get-Content -LiteralPath $digestsPath -Raw | ConvertFrom-Json -AsHashtable).GetEnumerator() | ForEach-Object { $digests[$_.Key] = $_.Value } }

$receiptPath = $null
$result = [ordered]@{
    operation='deploy'; target='desktop'; source=$source
    identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    started_utc=[DateTime]::UtcNow.ToString('o'); status='failed'; steps=@()
    selected_components=@($selected | Sort-Object)
}
$warnings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$record = $null
. "$PSScriptRoot/storage.ps1"
$storageOperation=Enter-DesktopStorageOperation
try {
    if ($mono.Count -and -not (Test-Path -LiteralPath "$source/deploy/windows/Build-IisPackage.ps1" -PathType Leaf)) {
        throw "SourcePath does not name the Laplace application checkout: $source"
    }
    if ($mono.Count -and -not $installation) {
        throw 'No IIS installation is declared. Run host setup first; setup.ps1 prepares development inputs and Install-IisRuntime.ps1 installs IIS.'
    }
    if($mono.Count){
    . "$source/deploy/windows/iis-runtime.ps1"
    try { $config = Read-IisInstallation $installation }
    catch [UnauthorizedAccessException] {
        throw "Cannot read $installation as $($result.identity). Run this command as the enrolled Windows operator. Host setup owns directory permissions; publication does not change account identities or ACLs."
    }
    $result.origin = $config.origin
    $revision = & git -c "safe.directory=$source" -C $source rev-parse HEAD
    if ($LASTEXITCODE) { throw 'Cannot identify the application source revision.' }
    $result.source_revision = "$revision".Trim()
    if($Package){
        $manifest=Test-IisPackage $Package
        $result.controller_revision=$result.source_revision
        $result.source_revision=$manifest.source_revision
        $result.prepared_package=$Package
    }
    $dirty = @(& git -c "safe.directory=$source" -C $source status --porcelain --untracked-files=no)
    if ($LASTEXITCODE) { throw 'Cannot inspect application source changes.' }
    $result.modified_source = $dirty
    if ($dirty.Count -and -not $Package) { Write-Host "Including $($dirty.Count) modified tracked files; the published package will have its own content hash." -ForegroundColor Yellow }
    }else{
        $result.installation=$modular.prefix
        $result.operations_revision=(& git -C $operations rev-parse HEAD).Trim()
    }

    # Load the declared toolchain rather than reconstructing a developer PATH.
    $developerShell = if ($env:LAPLACE_DEVSHELL) { $env:LAPLACE_DEVSHELL } else { "$operations/toolchain/windows/devshell.ps1" }
    if(-not $Package){. $developerShell}
    $tools=@('pwsh','git')
    if(-not $Package){
        if($selected.Contains('modular') -or @($mono | Where-Object {$_ -ne 'web'}).Count){$tools+=@('cmake','ninja','icx')}
        if(@($mono | Where-Object {$_ -in @('api','cli','uci','migrations')}).Count){$tools+='dotnet'}
        if($selected.Contains('web')){$tools+=@('node','npm')}
    }
    $missing = @($tools | Select-Object -Unique | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        throw "Developer setup is incomplete: $($missing -join ', '). Use setup.ps1 packages report; laplace-ops prepare owns locked development inputs."
    }
    $run = Join-Path $env:LAPLACE_WORK ('operations/desktop-deploy-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
    $null = New-Item -ItemType Directory -Path $run
    $receiptPath = Join-Path $run 'receipt.json'
    for ($i=0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $log = Join-Path $run ('{0:D2}.log' -f ($i+1))
        $record = [ordered]@{name=$step.name; status='running'; started_utc=[DateTime]::UtcNow.ToString('o'); log=$log; exit_code=$null}
        $result.steps += $record
        Write-Host "`n[$($i+1)/$($steps.Count)] $($step.name)" -ForegroundColor Cyan
        $digest = if ($step.inputs -and -not $Force -and -not $Package) { Get-StepDigest $step } else { $null }
        $record.inputs_digest = $digest
        if ($digest -and $digests[$step.name] -eq $digest) {
            $record.status = 'unchanged'; $record.finished_utc = [DateTime]::UtcNow.ToString('o'); $record.seconds = 0; $record.exit_code = 0
            Write-Host "Unchanged inputs ($($digest.Substring(0,12))): already produced; not run." -ForegroundColor Green
            continue
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $script = $step.script
        $executable=if($step.command){$step.command}else{'pwsh'}
        $stepArguments = $step.arguments
        if($step.component_receipt){$stepArguments+=@('-Receipt',(Join-Path $run 'components.json'))}
        if(-not $step.command){$stepArguments=@('-NoProfile','-File',$script)+$stepArguments}
        & $executable @stepArguments 2>&1 |
            ForEach-Object {
                $line = "$_"
                if ($line -match '(?i)\bwarning (?:CS|CA)\d+\b|^npm warn\b|^WARNING:') { $null = $warnings.Add($line) }
                $_
            } | Tee-Object -FilePath $log | Out-Host
        $exitCode = $LASTEXITCODE
        $clock.Stop()
        $record.finished_utc = [DateTime]::UtcNow.ToString('o')
        $record.seconds = [math]::Round($clock.Elapsed.TotalSeconds,2)
        $record.exit_code = $exitCode
        if ($exitCode -ne 0) {
            $record.status = 'failed'
            throw "$($step.name) failed (exit $exitCode). Log: $log"
        }
        $record.status = 'passed'
        if ($digest) {
            $digests[$step.name] = $digest
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $digestsPath)
            $digests | ConvertTo-Json | Set-Content -LiteralPath $digestsPath
        }
        Write-Host "Completed in $($record.seconds)s." -ForegroundColor Green
    }
    if($mono.Count){
        $active = Get-Content -LiteralPath (Join-Path $config.directory 'web/active.json') -Raw | ConvertFrom-Json
        $result.release = $active.revision
    }
    $componentReceipt=Join-Path $run 'components.json'
    if(Test-Path -LiteralPath $componentReceipt){$result.components=Get-Content -LiteralPath $componentReceipt -Raw | ConvertFrom-Json}
    if($selected.Contains('modular-web')){
        $webDeclaration=Get-Content -LiteralPath (Join-Path $PSScriptRoot ($env:COMPUTERNAME.ToLowerInvariant()+'-modular-web.json')) -Raw|ConvertFrom-Json
        $result.modular_web=Get-Content -LiteralPath (Join-Path $webDeclaration.directory 'active.json') -Raw|ConvertFrom-Json
        if(-not $mono.Count){$result.release=$result.modular_web.release}
    }
    if($selected.Contains('modular')){
    $result.modular_clients=Get-DesktopClientState -Declaration $modular
    Write-DesktopClientState $result.modular_clients
    $result.status = switch ($result.modular_clients.status) {
        'current' {'passed'}
        # Candidate initialization and a real native tool call already qualified
        # the selected MCP. Existing stdio conversations retain their own release
        # for their lifetime; they do not require another build or failed deploy.
        'reconnect_required' {'passed'}
        default { throw 'Cannot verify running modular clients; inspect modular_clients in the receipt.' }
    }
    }else{$result.status='passed'}
} catch {
    $result.error = $_.Exception.Message
    if ($record -and $record.status -eq 'running') {
        $clock.Stop()
        $record.status = 'failed'
        $record.finished_utc = [DateTime]::UtcNow.ToString('o')
        $record.seconds = [math]::Round($clock.Elapsed.TotalSeconds,2)
    }
    Write-Host "`nDesktop deployment failed: $($result.error)" -ForegroundColor Red
    if ($receiptPath) { Write-Host 'Deployment has not passed all stages. See the receipt for completed and failed work.' }
    else { Write-Host 'Preflight failed; no build, publication or migration stages ran.' }
} finally {
    try {
        $cleanup=Exit-DesktopStorageOperation -Operation $storageOperation -Modular (Get-DesktopClientDeclaration $ModularInstallation) -Iis $config -PassThru
        if($cleanup){$result.cleanup=@{status=$cleanup.status;receipt=$cleanup.receipt;removed=$cleanup.removed.Count}}
    }
    catch {
        $result.cleanup_error=$_.Exception.Message
        $result.status='failed'
        Write-Host "Desktop cleanup failed: $($result.cleanup_error). Run laplace-ops clean; do not rebuild installed components." -ForegroundColor Red
    }
    $result.finished_utc = [DateTime]::UtcNow.ToString('o')
    $result.warnings = @($warnings | Sort-Object)
    if ($receiptPath) {
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $receiptPath
        Write-Host "Deployment receipt: $receiptPath"
    }
}
if ($result.status -ne 'passed') { exit 1 }
if($mono.Count){
    Write-Host "`nDesktop deployment complete: $($result.origin)" -ForegroundColor Green
    Write-Host "Release: $($result.release)"
    Write-Host "Source: $($result.source_revision)"
}elseif($selected.Contains('modular-web')){
    Write-Host "`nModular browser deployment complete: $($result.modular_web.origin)" -ForegroundColor Green
    Write-Host "Release: $($result.modular_web.release)"
}else{Write-Host "`nModular desktop deployment complete: $($result.installation)" -ForegroundColor Green}
Write-Host "$($warnings.Count) distinct warning lines recorded; full output is retained in the stage logs."
exit 0
