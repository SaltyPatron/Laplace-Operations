#Requires -Version 7
[CmdletBinding()]
param([string]$Development, [string]$IisInstallation, [switch]$Publish)

function Set-DesktopUciDatabase {
    param([Parameter(Mandatory)]$Development, [Parameter(Mandatory)]$Iis,
          [Parameter(Mandatory)][string]$DataRoot)
    if(-not $Development.uci){return @{status='not_declared'}}
    if(-not [IO.Path]::IsPathFullyQualified($DataRoot) -or -not [IO.Path]::IsPathFullyQualified($Iis.directory)) {throw 'Desktop UCI requires absolute installed roots.'}
    if($Development.uci.service -notmatch '^[a-zA-Z0-9-]+$') {throw 'Invalid desktop UCI service declaration.'}
    if(-not @($Development.uci.profiles).Count -or @($Development.uci.profiles|Where-Object {$_ -notmatch '^[a-zA-Z0-9_-]+$'}).Count){throw 'Declare the desktop UCI profiles to bind.'}
    $root=Join-Path $DataRoot ('services/'+$Development.uci.service)
    $declaration=Join-Path $root 'agent/installation.json'
    if(-not(Test-Path -LiteralPath $declaration -PathType Leaf)){return @{status='not_installed';installation=$declaration}}
    $c=Get-Content -LiteralPath $declaration -Raw|ConvertFrom-Json
    if($c.host -ine $env:COMPUTERNAME -or $c.site -cne $Development.uci.service -or
        [IO.Path]::GetFullPath($c.directory) -ine [IO.Path]::GetFullPath($root) -or
        $Iis.database.authentication -cne 'sspi' -or $Iis.database.host -ine $env:COMPUTERNAME -or
        $Iis.database.host -ine $Development.database_host -or $Iis.database.port -ne $Development.port -or $Iis.database.substrate_database -cne $Development.substrate_database -or
        $Iis.database.substrate_role -cne $Development.substrate_role){throw 'Desktop UCI and application must select the declared local SSPI substrate.'}
    $identity='IIS APPPOOL\'+$c.site
    if($identity -notin $Development.windows_identities){throw 'The desktop UCI pool has no declared Windows database identity.'}
    $certificate=Join-Path $root 'postgres-root.crt'
    $connection=New-LaplaceWindowsDatabaseConnection @{
        host=$Iis.database.host;port=$Iis.database.port;database=$Iis.database.substrate_database
        role=$Iis.database.substrate_role;pool_max=$Iis.database.pool_max;authentication='sspi'
        root_certificate=$Development.root_certificate
    }
    $builder=[Data.Common.DbConnectionStringBuilder]::new();$builder.set_ConnectionString($connection)
    $builder['Root Certificate']=[string]$certificate
    $releaseRoot=Join-Path $Iis.directory 'web/releases'
    $selection=Join-Path $Iis.directory 'web/active.json'
    $active=Get-Content -LiteralPath $selection -Raw|ConvertFrom-Json
    if($active.revision -notmatch '^[a-f0-9]{64}$'){throw 'Invalid installed application release selection.'}
    $engine=Join-Path $releaseRoot ($active.revision+'/uci/laplace-uci.exe')
    if(-not(Test-Path -LiteralPath $engine -PathType Leaf)){throw 'The installed application release has no UCI engine.'}
    foreach($name in $Development.uci.profiles){
        $profile=$c.connector.profiles.$name
        if(-not $profile -or $profile.transport -cne 'process' -or $profile.implementation -cne 'laplace-mono' -or
            -not $profile.release -or $profile.executable -or $profile.release.executable -cne 'uci/laplace-uci.exe' -or
            [IO.Path]::GetFullPath($profile.release.directory) -ine [IO.Path]::GetFullPath($releaseRoot) -or
            [IO.Path]::GetFullPath($profile.release.selectionFile) -ine [IO.Path]::GetFullPath($selection)){
            throw "Desktop UCI profile '$name' does not select this application's published engine."
        }
        if(-not $profile.variables){$profile|Add-Member variables ([pscustomobject]@{}) -Force}
        $profile.variables|Add-Member LAPLACE_DB $builder.get_ConnectionString() -Force
        $profile.knowledge=$Development.client+'/'+$Iis.database.substrate_database
    }
    # Future setup/repair and the running connector read the same public binding.
    # The credential agent may refresh engine.env; explicit profile variables win.
    $c.engine=$engine;$c.engine_directory=Join-Path $Iis.directory 'web'
    $c.publish=Join-Path $root ('releases/'+$c.revision)
    if(-not(Test-Path -LiteralPath $c.publish -PathType Container)){throw 'The installed UCI connector release is missing.'}
    $c.database_certificate=[IO.File]::ReadAllText($Development.root_certificate)
    $outputs=[ordered]@{
        $certificate=$c.database_certificate
        $declaration=($c|ConvertTo-Json -Depth 20)
        (Join-Path $root 'connector.json')=($c.connector|ConvertTo-Json -Depth 20)
    }
    $changed=@()
    foreach($path in $outputs.Keys){
        if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Desktop UCI configuration must not be a reparse point.'}
    }
    foreach($path in $outputs.Keys){
        if(-not(Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -cne $outputs[$path]){
            Write-IisAtomic $path $outputs[$path];$changed+=$path
        }
    }
    @{status='configured';database_host=$Iis.database.host;database=$Iis.database.substrate_database
      database_role=$Iis.database.substrate_role;profiles=@($Development.uci.profiles);changed=$changed}
}

if($MyInvocation.InvocationName -ne '.'){
    $ErrorActionPreference='Stop'
    . "$PSScriptRoot/../laplace.env.ps1"
    . "$PSScriptRoot/../development/credentials.ps1"
    if(-not $Development){$Development=Join-Path $PSScriptRoot '../development/installation.json'}
    if(-not $IisInstallation){$IisInstallation=$env:LAPLACE_IIS_INSTALLATION}
    . (Join-Path $env:LAPLACE_SRC 'Laplace/deploy/windows/iis-runtime.ps1')
    $d=Read-DevelopmentConfig $Development
    $c=Read-IisInstallation $IisInstallation
    . "$PSScriptRoot/storage.ps1"
    $operation=Enter-DesktopStorageOperation
    try{
    $package=$null
    if($Publish -and $d.uci -and (Test-Path -LiteralPath (Join-Path $env:LAPLACE_DATA_ROOT ('services/'+$d.uci.service+'/agent/installation.json')))){
        $source=Join-Path $env:LAPLACE_SRC 'Laplace-UCI'
        $build=Join-Path $env:LAPLACE_BUILD 'Laplace-UCI'
        $package=Join-Path $build 'publish'
        $previousBuild=$env:LAPLACE_UCI_BUILD_ROOT
        try{
            $env:LAPLACE_UCI_BUILD_ROOT=$build
            & dotnet publish (Join-Path $source 'src/Laplace.Uci/Laplace.Uci.csproj') -c Release -r win-x64 --self-contained false -o $package
            if($LASTEXITCODE){throw 'Desktop UCI connector publication build failed.'}
        }finally{$env:LAPLACE_UCI_BUILD_ROOT=$previousBuild}
    }
    $result=Set-DesktopUciDatabase -Development $d -Iis $c -DataRoot $env:LAPLACE_DATA_ROOT
    if($result.status -eq 'configured' -and $package){
        $declaration=Join-Path $env:LAPLACE_DATA_ROOT ('services/'+$d.uci.service+'/agent/installation.json')
        & (Join-Path $env:LAPLACE_SRC 'Laplace-UCI/setup-iis.ps1') -Installation $declaration -Package $package -VerifyProfile $d.uci.profiles -Reload:([bool]$result.changed.Count)
        if($LASTEXITCODE){throw 'Desktop UCI connector publication or serving readback failed.'}
    }elseif($result.status -eq 'configured' -and $result.changed.Count){
        Add-Type -Path "$env:windir/System32/inetsrv/Microsoft.Web.Administration.dll"
        $manager=[Microsoft.Web.Administration.ServerManager]::new()
        try{
            $pool=$manager.ApplicationPools[$d.uci.service]
            if(-not $pool){throw 'The installed UCI application pool is missing.'}
            if($pool.State -eq 'Stopped'){$null=$pool.Start()}else{$null=$pool.Recycle()}
        }finally{$manager.Dispose()}
    }
    $result|ConvertTo-Json -Depth 6
    }finally{Exit-DesktopStorageOperation -Operation $operation -Iis $c}
}
