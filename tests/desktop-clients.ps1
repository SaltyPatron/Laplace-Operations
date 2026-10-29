# Exercise the mixed-release failure and retention decisions without terminating
# clients or requiring a local Laplace installation. Live CIM readback is separate.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installation/desktop-clients.ps1"
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('laplace-clients-'+[guid]::NewGuid().ToString('N'))
$prefix=Join-Path $temporary 'installed'
$selected=Join-Path $prefix 'releases/selected'
$old=Join-Path $prefix 'releases/old'
$unused=Join-Path $prefix 'releases/unused'
$savedHost=$env:COMPUTERNAME
try {
    $env:COMPUTERNAME='test-host'
    foreach ($release in @($selected,$old,$unused)) { $null=New-Item -ItemType Directory -Path (Join-Path $release 'bin') -Force }
    @{schema='laplace.modular-package/v1';revisions=@{'Laplace-MCP'='selected-revision'}} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $selected 'package.json')
    $installed=Join-Path $temporary 'installation.json'
    @{schema='laplace.modular-installation/v1';host='test-host';prefix=$prefix;release=$selected} |
        ConvertTo-Json | Set-Content -LiteralPath $installed
    $declaration=[pscustomobject]@{schema='laplace.modular-installation/v1';host='test-host';prefix=$prefix;installed_config=$installed}
    $declarationPath=Join-Path $temporary 'declaration.json'
    $declaration | ConvertTo-Json | Set-Content -LiteralPath $declarationPath
    $null=Get-DesktopClientDeclaration $declarationPath
    function Process([int]$Number,[string]$Name,[string]$Executable,[int]$Parent=0,[int]$Minute=0) {
        [pscustomobject]@{ProcessId=$Number;Name=$Name;ExecutablePath=$Executable;ParentProcessId=$Parent;
            CreationDate=[datetime]'2026-10-27T12:00:00Z' + [timespan]::FromMinutes($Minute);CommandLine="$Executable mcp"}
    }
    $snapshot=@(
        (Process 10 'codex.exe' (Join-Path $temporary 'codex.exe')),
        (Process 11 'python.exe' (Join-Path $temporary 'python.exe') 10 1),
        (Process 12 'lpm.exe' (Join-Path $old 'bin/lpm.exe') 11 2),
        (Process 13 'lpm.exe' (Join-Path $selected 'bin/lpm.exe') 11 3),
        (Process 14 'lpm.exe' (Join-Path $temporary 'unrelated/bin/lpm.exe'))
    )
    $state=Get-DesktopClientState -Declaration $declaration -Processes $snapshot
    if ($state.status -ne 'reconnect_required' -or $state.stale_count -ne 1 -or $state.processes.Count -ne 2) { throw 'Mixed-release clients were reported current or unrelated clients were included.' }
    $stale=@($state.processes | Where-Object pid -EQ 12)[0]
    if ($stale.mode -ne 'mcp-stdio' -or $stale.parents[1].pid -ne 10) { throw 'Client ownership was not traced.' }
    foreach ($release in @($selected,$old)) {
        $entry=@($state.releases | Where-Object release -EQ $release)[0]
        if (-not $entry.protected -or $entry.retirement -ne 'blocked') { throw 'Selected or active release was eligible for retirement.' }
    }
    $entry=@($state.releases | Where-Object release -EQ $unused)[0]
    if ($entry.retirement -ne 'requires_reference_audit') { throw 'No process does not establish that a release is disposable.' }
    $state=Get-DesktopClientState -Declaration $declaration -Processes @($snapshot | Where-Object ProcessId -NE 12)
    if ($state.status -ne 'current') { throw 'Disconnected old session remained stale.' }
    $snapshot[1].CreationDate=[datetime]'2026-10-27T14:00:00Z'
    $state=Get-DesktopClientState -Declaration $declaration -Processes $snapshot
    if (@($state.processes | Where-Object pid -EQ 12)[0].parents.Count) { throw 'A recycled parent PID was attributed to the client.' }
    $snapshot += Process 15 'lpm.exe' ''
    $state=Get-DesktopClientState -Declaration $declaration -Processes $snapshot
    if ($state.status -ne 'unverifiable' -or @($state.releases | Where-Object { -not $_.protected }).Count) { throw 'Incomplete process visibility permitted a successful inventory or retirement.' }
    $foreign=$declaration.PSObject.Copy(); $foreign.host='other-host'
    $foreign | ConvertTo-Json | Set-Content -LiteralPath $declarationPath
    $refused=$false
    try { $null=Get-DesktopClientDeclaration $declarationPath } catch { $refused=$true }
    if (-not $refused) { throw 'A foreign host declaration was accepted.' }
    . "$PSScriptRoot/../installation/desktop-uci.ps1"
    function New-LaplaceWindowsDatabaseConnection($Database){'Host=test-host;Database=substrate;Username=runtime;SSL Mode=VerifyFull;Require Auth=SSPI'}
    function Write-IisAtomic([string]$Path,[string]$Value){[IO.File]::WriteAllText($Path,$Value)}
    $data=Join-Path $temporary 'state'
    $uciRoot=Join-Path $data 'services/test-uci'
    $app=Join-Path $data 'services/test-api'
    $revision='a'*64
    $releaseRoot=Join-Path $app 'web/releases'
    $selection=Join-Path $app 'web/active.json'
    foreach($directory in @((Join-Path $uciRoot 'agent'),(Join-Path $uciRoot 'releases/connector'),(Join-Path $releaseRoot "$revision/uci"))){$null=New-Item -ItemType Directory -Force -Path $directory}
    Set-Content -LiteralPath (Join-Path $releaseRoot "$revision/uci/laplace-uci.exe") -Value ''
    @{revision=$revision}|ConvertTo-Json|Set-Content -LiteralPath $selection
    $certificate=Join-Path $temporary 'trust.crt';Set-Content -LiteralPath $certificate -Value 'declared desktop trust'
    $devConfig=[pscustomobject]@{client='test-host';database_host='test-host';port=5432;substrate_database='substrate';substrate_role='runtime'
        root_certificate=$certificate;windows_identities=@('IIS APPPOOL\test-uci');uci=@{service='test-uci';profiles=@('local')}}
    $iis=[pscustomobject]@{directory=$app;database=@{host='test-host';port=5432;authentication='sspi';substrate_database='substrate';substrate_role='runtime';pool_max=4}}
    $installedUci=Join-Path $uciRoot 'agent/installation.json'
    @{host='test-host';site='test-uci';directory=$uciRoot;revision='connector';engine='old';engine_directory='old';publish='old';database_certificate='old'
      connector=@{profiles=@{local=@{transport='process';implementation='laplace-mono';knowledge='old-server/substrate'
        release=@{directory=$releaseRoot;selectionFile=$selection;executable='uci/laplace-uci.exe'}};remote=@{transport='websocket';knowledge='external'}}}}|
        ConvertTo-Json -Depth 12|Set-Content -LiteralPath $installedUci
    $result=Set-DesktopUciDatabase $devConfig $iis $data
    if($result.status -ne 'configured' -or $result.changed.Count -ne 3){throw ('Desktop UCI binding did not write its three installed files: '+($result|ConvertTo-Json -Depth 5 -Compress))}
    $configured=Get-Content -LiteralPath $installedUci -Raw|ConvertFrom-Json
    if($configured.connector.profiles.local.knowledge -cne 'test-host/substrate' -or
       $configured.connector.profiles.local.variables.LAPLACE_DB -notmatch '(?i)Require Auth=SSPI' -or
       $configured.connector.profiles.remote.knowledge -cne 'external'){throw 'Desktop UCI binding changed the wrong profile or lost authentication.'}
    if((Set-DesktopUciDatabase $devConfig $iis $data).changed.Count){throw 'Unchanged desktop UCI binding rewrote its files.'}
    $iis.database.host='different-host';$refused=$false
    try{$null=Set-DesktopUciDatabase $devConfig $iis $data}catch{$refused=$true}
    if(-not $refused){throw 'A remote database silently replaced the declared local UCI binding.'}
    'Desktop clients: mixed releases, owner ancestry, PID reuse, retention, missing visibility and host isolation passed.'
} finally {
    $env:COMPUTERNAME=$savedHost
    # This test created only JSON and empty directories under its unique temp root.
    if ([IO.Path]::GetDirectoryName($temporary) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')) { throw 'Invalid test cleanup root.' }
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
