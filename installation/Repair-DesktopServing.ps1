#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Receipt,
    [switch]$Preflight
)
$ErrorActionPreference='Stop'
$operator=Get-Content "$PSScriptRoot/hart-desktop-operator.json" -Raw | ConvertFrom-Json
$windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($windowsIdentity.User.Value -ne $operator.windows_sid -or $windowsIdentity.Name -ne $operator.windows_identity){
    throw 'Run as the declared Windows operator.'
}
$desktopTargets=@($operator.targets | Where-Object authentication -EQ sspi)
if($desktopTargets.Count -ne 1 -or $desktopTargets[0].host -ine $env:COMPUTERNAME){throw 'Select this desktop installation.'}
$desktopTarget=$desktopTargets[0]
$Source=[IO.Path]::GetFullPath($Source)
$Package=[IO.Path]::GetFullPath($Package)
$env:LAPLACE_ROOT=$Source
. "$PSScriptRoot/../laplace.env.ps1"
. "$Source/scripts/win/laplace-paths.ps1"
Import-LaplaceEnv
& "$Source/scripts/win/assert-build-source.ps1" -SourceDirectory "$Source/engine" -BuildDirectory $env:LAPLACE_ENGINE_BUILD
& "$Source/scripts/win/assert-build-source.ps1" -SourceDirectory "$Source/extension" -BuildDirectory $env:LAPLACE_EXT_BUILD
. "$Source/deploy/windows/iis-runtime.ps1"
$candidate=Test-IisPackage $Package
$runtimeDifferences=@(& git -C $Source diff --name-only $candidate.source_revision -- engine extension app web scripts/win deploy)
if($LASTEXITCODE -or $runtimeDifferences.Count){throw 'The candidate and selected runtime source differ; rebuild before activation.'}
foreach($library in 'core','dynamics'){
    $built=Join-Path $env:LAPLACE_ENGINE_BUILD "$library/laplace_$library.dll"
    if((Get-FileHash $built).Hash -ne (Get-FileHash (Join-Path $Package "laplace_$library.dll")).Hash){
        throw 'Application and PostgreSQL native libraries come from different builds.'
    }
}
foreach($pathPair in @(@($env:LAPLACE_PG_DIR,$desktopTarget.prefix),@($env:LAPLACE_PGDATA,$desktopTarget.data))){
    if([IO.Path]::GetFullPath($pathPair[0]).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($pathPair[1]).TrimEnd('\','/')){
        throw 'The source environment selects another PostgreSQL installation.'
    }
}
$env:LAPLACE_CONNINFO="host=$($desktopTarget.host) hostaddr=127.0.0.1 port=$($desktopTarget.port) user=$($operator.role) dbname=postgres sslmode=verify-full sslrootcert='$($operator.state.Replace('\','/'))/hart-desktop-postgresql.crt' require_auth=sspi connect_timeout=10"
. "$PSScriptRoot/../tune-pg.ps1"
TuneLocalOrDie
TuneValidatePlan
$liveData=(TunePsql 'SHOW data_directory') -join ''
if([IO.Path]::GetFullPath($liveData).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($desktopTarget.data).TrimEnd('\','/')){throw 'The server uses another data directory.'}
$cluster=(TunePsql 'SELECT system_identifier FROM pg_control_system()') -join ''
$installationPath=$env:LAPLACE_IIS_INSTALLATION
$installed=Read-IisInstallation $installationPath
$webRoot=Join-Path $installed.directory 'web'
$previousPointer=Get-Content (Join-Path $webRoot 'active.json') -Raw | ConvertFrom-Json
$previousPackage=Join-Path $webRoot ('releases/'+$previousPointer.revision)
$null=Test-IisPackage $previousPackage
$declaredResources=TuneDeclared
$activation=[ordered]@{host=$env:COMPUTERNAME;cluster=$cluster;source_revision=$candidate.source_revision;
    package=$Package;package_revision=$candidate.revision;previous_package=$previousPackage;
    postgres_service=$desktopTarget.postgres_service;data=$desktopTarget.data;wal=$env:LAPLACE_PGWAL;
    declared_resources=$declaredResources;stage='preflight';completed=$false}
function SaveActivation { $activation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Receipt }
SaveActivation
if($Preflight){$activation | ConvertTo-Json -Depth 8;return}
if(-not ([Security.Principal.WindowsPrincipal]::new($windowsIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Activation requires Windows service-control elevation; preflight completed without changing the installation.'
}
$operationLock=[IO.File]::Open((Join-Path $operator.work 'desktop-serving-repair.lock'),'OpenOrCreate','ReadWrite','None')
$backup=Join-Path $operator.work ('serving-backup-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
$backupFiles=@()
$mutated=$false
try{
    if(TuneIngesting){throw 'An ingest owns the database.'}
    if([int]((TunePsql "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND state<>'idle' AND pid<>pg_backend_pid()") -join '') -gt 0){
        throw 'A database operation is active; leave it running and retry activation when idle.'
    }
    $null=New-Item -ItemType Directory -Path $backup
    $acl=Get-Acl $backup
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($windowsIdentity.User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $backup -AclObject $acl
    $paths=@((Join-Path $desktopTarget.data 'postgresql.auto.conf'),$installationPath,
        (Join-Path $webRoot 'web.config'),(Join-Path $webRoot 'active.json'))
    $paths+=@(Get-ChildItem -LiteralPath (Join-Path $desktopTarget.prefix 'bin') -File -Filter '*.dll' | ForEach-Object FullName)
    $paths+=@(Get-ChildItem -LiteralPath (Join-Path $env:LAPLACE_DEPLOY 'lib') -File | ForEach-Object FullName)
    $paths+=@(Get-ChildItem -LiteralPath (Join-Path $env:LAPLACE_DEPLOY 'share') -File -Recurse | ForEach-Object FullName)
    foreach($path in $paths){
        $saved=Join-Path $backup ('file-'+$backupFiles.Count)
        Copy-Item -LiteralPath $path -Destination $saved
        $backupFiles+=@{original=$path;backup=$saved;sha256=(Get-FileHash -LiteralPath $path).Hash}
    }
    $backupFiles | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $backup 'files.json')
    $activation.backup=$backup
    $activation.stage='restore-resource-declarations';SaveActivation
    $mutated=$true
    TuneApply
    $activation.stage='install-native-with-service-stopped';SaveActivation
    Stop-Service -Name $desktopTarget.postgres_service
    . "$PSScriptRoot/../toolchain/windows/devshell.ps1"
    & "$Source/scripts/win/install-extensions.cmd" --files-only --skip-build
    if($LASTEXITCODE){throw 'Native installation failed.'}
    Start-Service -Name $desktopTarget.postgres_service
    $available=$false
    foreach($attempt in 1..30){
        try{$readCluster=(TunePsql 'SELECT system_identifier FROM pg_control_system()') -join '';if($readCluster -eq $cluster){$available=$true;break}}catch{}
        Start-Sleep -Seconds 1
    }
    if(-not $available){throw 'The original cluster did not become available after native activation.'}
    $activation.stage='verify-restored-resources';SaveActivation
    & "$PSScriptRoot/Verify-DesktopResources.ps1" | Set-Content ($Receipt+'.resources.json')
    $activation.stage='activate-matching-iis-package';SaveActivation
    & "$Source/deploy/windows/Install-LaplaceSite.ps1" -Installation $installationPath -Package $Package
    $activation.stage='verify-access-and-clients';SaveActivation
    & "$PSScriptRoot/Verify-DesktopDatabases.ps1" | Set-Content ($Receipt+'.databases.json')
    & "$PSScriptRoot/Verify-PlatformAccess.ps1" | Set-Content ($Receipt+'.platform.json')
    $activation.stage='activated-and-verified';$activation.completed=$true;SaveActivation
}catch{
    $failure=$_.Exception.Message
    if($mutated){
        $activation.stage='rollback';SaveActivation
        try{
            Stop-Service -Name $desktopTarget.postgres_service -ErrorAction SilentlyContinue
            foreach($file in $backupFiles){Copy-Item -LiteralPath $file.backup -Destination $file.original -Force}
            Start-Service -Name $desktopTarget.postgres_service
            & "$Source/deploy/windows/Install-LaplaceSite.ps1" -Installation $installationPath -Package $previousPackage
            $activation.rollback='restored-previous-files-and-package'
        }catch{$activation.rollback='failed';$activation.rollback_error=$_.Exception.Message}
    }
    $activation.stage='failed';$activation.error=$failure;SaveActivation
    throw $failure
}finally{$operationLock.Dispose()}
