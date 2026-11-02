#requires -Version 7
[CmdletBinding()]
param([string]$Installation=(Join-Path $PSScriptRoot 'hart-desktop-modular-web.json'),[switch]$PrepareOnly)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/modular-web.ps1"
. "$PSScriptRoot/storage.ps1"
$c=Get-Content -LiteralPath $Installation -Raw|ConvertFrom-Json
if($c.schema -cne 'laplace.modular-web-installation/v1'){throw 'Unknown modular web declaration.'}
$root=[IO.Path]::GetFullPath($c.directory)
$source=[IO.Path]::GetFullPath($c.source)
$build=[IO.Path]::GetFullPath($c.build)
$base=$c.origin.TrimEnd('/')+$c.application+'/'
$hostDirectory=Join-Path $root 'web'
$logs=Join-Path $root 'state/logs/iis'
foreach($path in @($root,$source,$build,$hostDirectory)){
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse-point installation path: $path"}
}
$hostFile=Join-Path $root 'state/hosting.json'
if(-not $PrepareOnly){
    $hosting=Get-Content -LiteralPath $hostFile -Raw|ConvertFrom-Json
    if($hosting.schema -cne 'laplace.modular-web-host/v1' -or $hosting.directory -ine $hostDirectory -or $hosting.origin -cne $c.origin -or $hosting.application -cne $c.application -or $hosting.pool -cne $c.pool){throw 'The provisioned IIS host differs from this declaration.'}
}
$selected=Get-Content -LiteralPath $c.native.client_installation -Raw|ConvertFrom-Json
if($selected.database -cne $c.native.database){throw 'The installed modular client names another database.'}
$nativeRoot=[IO.Path]::GetFullPath($selected.release)
$prepared=Join-Path $nativeRoot 'share/prepared'
foreach($relative in @('package.json','bin/lpm.exe','share/prepared/tier0.bin','share/prepared/tier0.flags','share/prepared/tier0.highway')){
    if(-not(Test-Path -LiteralPath (Join-Path $nativeRoot $relative) -PathType Leaf)){throw "The installed modular package is incomplete: $relative"}
}
$nativeConfig=Get-Content -LiteralPath (Join-Path $root 'state/native.json') -Raw|ConvertFrom-Json
$nativeConfig.release=$nativeRoot
$nativeConfig|Add-Member code_roots @($c.native.code_roots) -Force
$nativeConfig|Add-Member work (Join-Path $root 'state/logs/native') -Force
$operation=Enter-DesktopStorageOperation
$publicationLock=$null
try{
    $publicationLock=[IO.File]::Open((Join-Path $root 'state/publication.lock'),'OpenOrCreate','ReadWrite','None')
    $publish=Join-Path $build 'publish'
    if(Test-Path -LiteralPath $publish){
        $resolved=[IO.Path]::GetFullPath($publish)
        if(-not $resolved.StartsWith($build.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or ((Get-Item -LiteralPath $publish -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Publish output escaped its build directory.'}
        Remove-Item -LiteralPath $publish -Recurse -Force
    }
    & dotnet publish (Join-Path $source 'Laplace.Modular.Web.csproj') -c Release --self-contained false "-p:LAPLACE_WEB_BUILD=$build" -o $publish --nologo
    if($LASTEXITCODE){throw 'Modular browser build failed.'}
    $null=New-Item -ItemType Directory -Path (Join-Path $publish 'native') -Force
    Copy-Item -LiteralPath (Join-Path $nativeRoot 'bin/lpm.exe') -Destination (Join-Path $publish 'native/lpm.exe')
    Copy-Item -LiteralPath (Join-Path $prepared 'tier0.highway') -Destination (Join-Path $publish 'native/tier0.highway')
    Write-ModularWebJson (Join-Path $publish 'native-resources.json') $nativeConfig
    Write-ModularWebJson (Join-Path $publish 'appsettings.Production.json') ([ordered]@{SharedIdentityPath=$c.identity_path;NativeConfigFile='native-resources.json';McpIdentityEndpoint=($c.origin.TrimEnd('/')+'/mcp')})
    # The stable IIS host owns web.config. It is not application package content.
    $packageWebConfig=Join-Path $publish 'web.config'
    if(Test-Path -LiteralPath $packageWebConfig){Remove-Item -LiteralPath $packageWebConfig}
    $inventory=@(Get-ChildItem -LiteralPath $publish -File -Recurse|Sort-Object FullName|ForEach-Object {
        [ordered]@{path=[IO.Path]::GetRelativePath($publish,$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $identity=ConvertTo-Json -InputObject $inventory -Depth 5 -Compress
    $release=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $destination=Join-Path $root ('releases/'+$release)
    if(-not(Test-Path -LiteralPath $destination)){
        $null=New-Item -ItemType Directory -Path $destination
        Copy-Item -Path (Join-Path $publish '*') -Destination $destination -Recurse
        Write-ModularWebJson (Join-Path $destination 'release.json') ([ordered]@{release=$release;created_utc=[DateTime]::UtcNow.ToString('o');files=$inventory;native_resources=$nativeRoot})
    }
    $record=Get-Content -LiteralPath (Join-Path $destination 'release.json') -Raw|ConvertFrom-Json
    if($record.release -cne $release){throw 'The immutable modular release has another identity.'}
    foreach($file in $inventory){
        if((Get-FileHash -LiteralPath (Join-Path $destination $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256){throw 'The immutable modular release differs from this package.'}
    }
    if($PrepareOnly){[ordered]@{status='prepared';release=$release;directory=$destination;native_resources=$nativeRoot}|ConvertTo-Json;return}
    $readerSid=([Security.Principal.NTAccount]::new('IIS APPPOOL',$c.pool)).Translate([Security.Principal.SecurityIdentifier])
    $nativeAccess=Grant-ModularWebNativeRead $nativeRoot $readerSid
    $configuration=Join-Path $hostDirectory 'web.config'
    $previousConfig=if(Test-Path -LiteralPath $configuration){[IO.File]::ReadAllText($configuration)}else{$null}
    $previous=if(Test-Path -LiteralPath (Join-Path $root 'active.json')){Get-Content -LiteralPath (Join-Path $root 'active.json') -Raw|ConvertFrom-Json}else{$null}
    $desired=Get-ModularWebConfig $hostDirectory $destination $release $logs
    $changed=$previousConfig -cne $desired
    try{
        if($changed){
            Write-ModularWebFile $configuration $desired
            Restart-ModularWeb $hostDirectory $base
        }
        $health=$null
        for($attempt=0;$attempt -lt 12;$attempt++){
            try{$health=Invoke-RestMethod ($base+'health') -TimeoutSec 15;if($health.release -ceq $release){break}}catch{}
            Start-Sleep -Seconds 1
        }
        if($health.release -cne $release){throw 'Installed modular health does not identify the selected package.'}
        $catalog=Invoke-RestMethod ($base+'api/catalog') -TimeoutSec 60
        if($catalog.database -cne $c.native.database -or $catalog.read_only -ne $true){throw 'The native reader is not read-only on the declared database.'}
        $lookup=Invoke-RestMethod ($base+'api/lookup?q=Laplace') -TimeoutSec 60
        if($lookup.database -cne $c.native.database -or $lookup.id -notmatch '^[a-f0-9]{32}$'){throw 'Live native lookup verification failed.'}
        $schema=Invoke-RestMethod ($base+'api/schema') -TimeoutSec 60
        $mono=Invoke-WebRequest ($c.origin.TrimEnd('/')+'/health') -TimeoutSec 15
        if($mono.StatusCode -ne 200){throw 'The parent application is unavailable.'}
        $clientPath=Join-Path $env:APPDATA 'Code/User/mcp.json'
        $mcpClient=@{status='not_configured'}
        if(Test-Path -LiteralPath $clientPath){
            $client=Get-Content -Raw -LiteralPath $clientPath|ConvertFrom-Json
            if($client.servers.'laplace-code'){
                $headers=@{Accept='application/json, text/event-stream'}
                foreach($property in $client.servers.laplace.headers.PSObject.Properties){$headers[$property.Name]=$property.Value}
                $request=@{jsonrpc='2.0';id=1;method='tools/list'}|ConvertTo-Json -Compress
                $tools=Invoke-RestMethod ($base+'mcp') -Method Post -Headers $headers -ContentType 'application/json' -Body $request -TimeoutSec 120
                foreach($required in @('code_search','reindex','code_where','code_callers','code_callees','file_outline')){
                    if($required -notin @($tools.result.tools.name)){throw "The installed IIS MCP lacks $required."}
                }
                $request=@{jsonrpc='2.0';id=2;method='tools/call';params=@{name='code_search';arguments=@{query='NativeRuntime';limit=1}}}|ConvertTo-Json -Depth 8 -Compress
                $read=Invoke-RestMethod ($base+'mcp') -Method Post -Headers $headers -ContentType 'application/json' -Body $request -TimeoutSec 130
                if($read.error -or $read.result.isError){throw 'The installed IIS native code search failed.'}
                $mcpClient=Set-ModularMcpClient $clientPath $c.origin ($base+'mcp')
            }
        }
        $receipt=[ordered]@{
            status='verified';utc=[DateTime]::UtcNow.ToString('o');host=$env:COMPUTERNAME;origin=$base;release=$release;directory=$destination
            source_revision=(& git -C $source rev-parse HEAD).Trim();source_changes=@(& git -C $source status --porcelain -- .)
            site=$c.site;application=$c.application;pool=$c.pool;host_directory=$hostDirectory;data='native-live';database=$catalog.database;read_only=$catalog.read_only
            native_resources=$nativeRoot;native_access=$nativeAccess;native_binary_sha256=(Get-FileHash -LiteralPath (Join-Path $destination 'native/lpm.exe')).Hash.ToLowerInvariant();native_cache=$schema.highway
            mono_status=$mono.StatusCode;previous=$(if($changed){$previous.directory}else{$previous.previous});activation=$(if($changed){'restarted'}else{'reused'})
            mcp_client=$mcpClient
        }
        $receiptFile=Join-Path $c.receipts ('deploy-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.json')
        Write-ModularWebJson $receiptFile $receipt
        Write-ModularWebJson (Join-Path $root 'active.json') $receipt
        $receipt|ConvertTo-Json -Depth 8
        Write-Host "Receipt: $receiptFile"
    }catch{
        if($changed){
            if($previousConfig){Write-ModularWebFile $configuration $previousConfig;Restart-ModularWeb $hostDirectory $base}
            else{Remove-Item -LiteralPath $configuration}
        }
        throw
    }
}finally{
    if($publicationLock){$publicationLock.Dispose()}
    Exit-DesktopStorageOperation -Operation $operation
}
