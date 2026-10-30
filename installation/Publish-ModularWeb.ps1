#requires -Version 7
[CmdletBinding()]
param([string]$Installation = (Join-Path $PSScriptRoot 'hart-desktop-modular-web.json'))
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
if($c.schema -cne 'laplace.modular-web-installation/v1'){throw 'Unknown modular web declaration.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Creating or updating the modular IIS application requires an elevated installation shell.'
}
if($c.application -notmatch '^/[a-z][a-z0-9-]*$' -or $c.pool -notmatch '^[a-z][a-z0-9-]*$'){
    throw 'Declare one explicit child application and its dedicated pool.'
}
$root=[IO.Path]::GetFullPath($c.directory)
$source=[IO.Path]::GetFullPath($c.source)
$build=[IO.Path]::GetFullPath($c.build)
$origin=[Uri]$c.origin
if($origin.Scheme -cne 'https' -or $origin.AbsolutePath -ne '/' -or $origin.UserInfo){throw 'Declare the existing HTTPS origin.'}
$operator=Get-Content -LiteralPath (Join-Path $PSScriptRoot $c.operator_declaration) -Raw | ConvertFrom-Json
$operatorSid=[Security.Principal.SecurityIdentifier]::new($operator.windows_sid)
if($identity.User.Value -ne $operatorSid.Value){throw 'Run as the declared desktop operator.'}
foreach($path in @($root,$source,$build)){
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw "Refusing a reparse-point installation path: $path"
    }
}
Add-Type -Path "$env:windir/System32/inetsrv/Microsoft.Web.Administration.dll"
$m=[Microsoft.Web.Administration.ServerManager]::new()
try{
    $site=$m.Sites[$c.site]
    if(-not $site){throw 'The declared parent IIS site is not installed.'}
    if(-not @($site.Bindings | Where-Object {$_.Protocol -eq 'https' -and $_.Host -ieq $origin.DnsSafeHost -and $_.EndPoint.Port -eq $origin.Port}).Count){throw 'The parent site does not own the declared HTTPS origin.'}
    $monoPath=$site.Applications['/'].VirtualDirectories['/'].PhysicalPath
    $existing=$site.Applications[$c.application]
    $previous=if($existing){$existing.VirtualDirectories['/'].PhysicalPath}else{$null}
    if($previous -and -not [IO.Path]::GetFullPath($previous).StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        throw 'The child application is owned by a different installation.'
    }
    if($existing -and $existing.ApplicationPoolName -cne $c.pool){throw 'The child application uses a different pool.'}
    $other=@($m.Sites | ForEach-Object {$siteName=$_.Name; $_.Applications | Where-Object {$_.ApplicationPoolName -eq $c.pool -and ($siteName -ne $c.site -or $_.Path -ne $c.application)}})
    if($other.Count){throw 'The modular pool is shared with another application.'}
}finally{$m.Dispose()}

$publish=Join-Path $build 'publish'
if(-not (Test-Path -LiteralPath (Join-Path $root 'state/native.json'))){throw 'Run Initialize-ModularWeb.ps1 to provision the native reader identity first.'}
if(-not (Test-Path -LiteralPath $c.native.binary)){throw 'Build the declared modular native reader before publication.'}
if(Test-Path -LiteralPath $publish){
    $resolved=[IO.Path]::GetFullPath($publish)
    if(-not $resolved.StartsWith($build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Get-Item -LiteralPath $publish -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Publish output must stay within the declared build directory.'}
    Remove-Item -LiteralPath $publish -Recurse -Force
}
& dotnet publish (Join-Path $source 'Laplace.Modular.Web.csproj') -c Release --self-contained false "-p:LAPLACE_WEB_BUILD=$build" -o $publish --nologo
if($LASTEXITCODE){throw 'Modular browser build failed.'}
$null=New-Item -ItemType Directory -Path (Join-Path $publish 'native') -Force
Copy-Item -LiteralPath $c.native.binary -Destination (Join-Path $publish 'native/lpm.exe')
$nativeConfig=Join-Path $root 'state/native.json'
# A Core sub-application inherits the parent's ANCM handler and selects its own process.
$logs=Join-Path $root 'state/logs/iis'
$webConfig=@"
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer><aspNetCore processPath=".\Laplace.Modular.Web.exe" hostingModel="inprocess" stdoutLogEnabled="true" stdoutLogFile="$logs"/></system.webServer></configuration>
"@
[IO.File]::WriteAllText((Join-Path $publish 'web.config'),$webConfig,[Text.UTF8Encoding]::new($false))
$inventory=@(Get-ChildItem -LiteralPath $publish -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($publish,$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$manifest=ConvertTo-Json -InputObject ([ordered]@{files=$inventory;identity_path=$c.identity_path;native_config=$nativeConfig;hosting='iis-sub-application'}) -Depth 8 -Compress
$release=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
$destination=Join-Path $root "releases/$release"
$null=New-Item -ItemType Directory -Force -Path $root,(Join-Path $root 'state/logs'),$c.receipts
if(Test-Path -LiteralPath $destination){
    $record=Get-Content -LiteralPath (Join-Path $destination 'release.json') -Raw | ConvertFrom-Json
    if($record.release -cne $release){throw 'Existing release has an invalid manifest.'}
    $runtimeConfig=Get-Content -LiteralPath (Join-Path $destination 'appsettings.Production.json') -Raw | ConvertFrom-Json
    if($runtimeConfig.ReleaseId -cne $release -or $runtimeConfig.SharedIdentityPath -cne $c.identity_path -or $runtimeConfig.NativeConfigFile -cne $nativeConfig){throw 'Existing release runtime configuration differs from the declaration.'}
    foreach($file in $inventory){
        if((Get-FileHash -LiteralPath (Join-Path $destination $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256){throw 'Existing immutable release differs from the package.'}
    }
}else{
    $null=New-Item -ItemType Directory -Force -Path $destination
    Copy-Item -Path (Join-Path $publish '*') -Destination $destination -Recurse
    @{ReleaseId=$release;SharedIdentityPath=$c.identity_path;NativeConfigFile=$nativeConfig}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $destination 'appsettings.Production.json') -Encoding utf8NoBOM
    @{release=$release;created_utc=[DateTime]::UtcNow.ToString('o');files=$inventory}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $destination 'release.json') -Encoding utf8NoBOM
}

$m=[Microsoft.Web.Administration.ServerManager]::new()
try{
    $pool=$m.ApplicationPools[$c.pool]
    if(-not $pool){$pool=$m.ApplicationPools.Add($c.pool)}
    $pool.ManagedRuntimeVersion=''
    $pool.StartMode=[Microsoft.Web.Administration.StartMode]::AlwaysRunning
    $pool.AutoStart=$true
    $pool.ProcessModel.IdentityType=[Microsoft.Web.Administration.ProcessModelIdentityType]::ApplicationPoolIdentity
    $m.CommitChanges()
}finally{$m.Dispose()}

$poolSid=([Security.Principal.NTAccount]::new('IIS APPPOOL',$c.pool)).Translate([Security.Principal.SecurityIdentifier])
function Grant-DirectoryAccess([string]$Path,[Security.Principal.IdentityReference]$Principal,[Security.AccessControl.FileSystemRights]$Rights){
    $acl=Get-Acl -LiteralPath $Path
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($Principal,$Rights,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule);Set-Acl -LiteralPath $Path -AclObject $acl
}
Grant-DirectoryAccess $root ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')) FullControl
Grant-DirectoryAccess $root ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) FullControl
Grant-DirectoryAccess $root $operatorSid FullControl
Grant-DirectoryAccess $root $poolSid ReadAndExecute
Grant-DirectoryAccess (Join-Path $root 'state') $poolSid ReadAndExecute
Grant-DirectoryAccess (Join-Path $root 'state/logs') $poolSid Modify
# IIS reads ancestor configuration as the child pool. Read this directory and
# its immediate files only, including replacement web.config files on mono deploy.
# Do not inherit access into the parent's releases or runtime state.
$parentAcl=Get-Acl -LiteralPath $monoPath
$parentRule=[Security.AccessControl.FileSystemAccessRule]::new($poolSid,[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.InheritanceFlags]::ObjectInherit,[Security.AccessControl.PropagationFlags]::NoPropagateInherit,[Security.AccessControl.AccessControlType]::Allow)
$parentAcl.SetAccessRule($parentRule)
Set-Acl -LiteralPath $monoPath -AclObject $parentAcl

$activated=$false
try{
    $m=[Microsoft.Web.Administration.ServerManager]::new()
    try{
        $site=$m.Sites[$c.site];$application=$site.Applications[$c.application]
        if(-not $application){$application=$site.Applications.Add($c.application,$destination)}
        $application.VirtualDirectories['/'].PhysicalPath=$destination
        $application.ApplicationPoolName=$c.pool
        $application.SetAttributeValue('preloadEnabled',$true)
        $m.CommitChanges();$activated=$true
        $pool=$m.ApplicationPools[$c.pool]
        if($pool.State -eq 'Stopped'){$null=$pool.Start()}else{$null=$pool.Recycle()}
    }finally{$m.Dispose()}
    $base=$origin.GetLeftPart([UriPartial]::Authority)+$c.application+'/'
    $health=$null
    for($attempt=0;$attempt -lt 10;$attempt++){
        try{$health=Invoke-RestMethod ($base+'health') -TimeoutSec 10;if($health.release -ceq $release -and $health.service -ceq 'laplace-modular-web'){break}}catch{}
        Start-Sleep -Seconds 1
    }
    if(-not $health -or $health.release -cne $release){
        $diagnostic=Invoke-WebRequest ($base+'health') -SkipHttpErrorCheck -TimeoutSec 10
        $content=if($diagnostic.Content -is [byte[]]){[Text.Encoding]::UTF8.GetString($diagnostic.Content)}else{[string]$diagnostic.Content}
        throw "Installed modular health mismatch: HTTP $($diagnostic.StatusCode), $($diagnostic.Headers['Content-Type']), $($content.Substring(0,[Math]::Min(300,$content.Length)))"
    }
    $page=Invoke-WebRequest $base -TimeoutSec 15
    if($page.StatusCode -ne 200 -or $page.Content -notmatch 'runtime.js'){throw 'IIS did not serve the modular browser document.'}
    $catalog=Invoke-RestMethod ($base+'api/catalog') -TimeoutSec 60
    if($catalog.database -cne $c.native.database -or $catalog.read_only -ne $true){throw 'Native reader is not connected read-only to the declared modular database.'}
    $lookup=Invoke-RestMethod ($base+'api/lookup?q=Laplace') -TimeoutSec 60
    if($lookup.database -cne $c.native.database -or $lookup.id -notmatch '^[a-f0-9]{32}$'){throw 'Live native lookup verification failed.'}
    $mono=Invoke-WebRequest ($origin.GetLeftPart([UriPartial]::Authority)+'/health') -TimeoutSec 15
    $m=[Microsoft.Web.Administration.ServerManager]::new()
    try{
        if($m.Sites[$c.site].Applications['/'].VirtualDirectories['/'].PhysicalPath -cne $monoPath){throw 'Parent mono application path changed during publication.'}
        $binding=@($m.Sites[$c.site].Bindings | ForEach-Object {$_.BindingInformation})
    }finally{$m.Dispose()}
    $sourceRevision=(& git -C $source rev-parse HEAD).Trim()
    $sourceChanges=@(& git -C $source status --porcelain -- .)
    $workspace=Split-Path (Split-Path $source -Parent) -Parent
    $components=@(foreach($repository in @('Laplace-MCP','Laplace-Native','Laplace-Engine','Laplace-Operations')){
        $checkout=Join-Path $workspace $repository
        [ordered]@{repository=$repository;revision=(& git -C $checkout rev-parse HEAD).Trim();working_changes=@(& git -C $checkout status --porcelain)}
    })
    $nativeInstallation=Get-Content -LiteralPath $nativeConfig -Raw|ConvertFrom-Json
    $receipt=[ordered]@{status='verified';host=$env:COMPUTERNAME;utc=[DateTime]::UtcNow.ToString('o');origin=$base;release=$release;source_revision=$sourceRevision;source_changes=$sourceChanges;components=$components;directory=$destination;site=$c.site;application=$c.application;pool=$c.pool;bindings=$binding;identity='existing same-origin /v1/auth';data='native-live';database=$catalog.database;read_only=$catalog.read_only;native_resources=$nativeInstallation.release;native_binary_sha256=(Get-FileHash -LiteralPath $c.native.binary -Algorithm SHA256).Hash.ToLowerInvariant();mono_status=$mono.StatusCode;mono_directory=$monoPath;previous=$previous}
    $receiptFile=Join-Path $c.receipts ('deploy-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.json')
    $receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $receiptFile -Encoding utf8NoBOM
    $receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root 'active.json') -Encoding utf8NoBOM
    $receipt|ConvertTo-Json -Depth 8
    Write-Host "Receipt: $receiptFile"
}catch{
    if($activated){
        $m=[Microsoft.Web.Administration.ServerManager]::new()
        try{
            $application=$m.Sites[$c.site].Applications[$c.application]
            if($previous){$application.VirtualDirectories['/'].PhysicalPath=$previous}else{if($application){$m.Sites[$c.site].Applications.Remove($application)}}
            $m.CommitChanges()
            $pool=$m.ApplicationPools[$c.pool];if($pool -and $pool.State -eq 'Started'){$null=$pool.Recycle()}
        }finally{$m.Dispose()}
    }
    throw
}
