#Requires -Version 7
$ErrorActionPreference='Stop'
$initialOwner=$env:LAPLACE_STORAGE_OWNER_PID
. "$PSScriptRoot/../installation/storage.ps1"
$script:readWebReferences=(Get-Command Get-StorageModularWebReferences).ScriptBlock
$script:webReferenceFixture=''
function Get-StorageModularWebReferences { & $script:readWebReferences -Configuration $script:webReferenceFixture }
function Invoke-StorageDatabaseCleanup { return @([pscustomobject]@{database='fixture';status='passed';loads=@()}) }
$root=Join-Path ([IO.Path]::GetTempPath()) ('laplace-storage-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function Require($Value,[string]$Message) { if(-not $Value){throw $Message} }
function Fixture([string]$Path,[string]$Marker,[string]$Revision) {
    $null=New-Item -ItemType Directory -Path $Path -Force
    @{revision=$Revision;files=@(@{path='test.dll';sha256=('0'*64)})} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Path $Marker)
    Set-Content -LiteralPath (Join-Path $Path 'test.dll') -Value 'fixture'
    return $Path
}
function HistoryFixture([string]$Family,[int]$Sequence,$Record) {
    $time=[DateTime]::new(2020,1,1,0,0,0,[DateTimeKind]::Utc).AddMinutes($Sequence)
    $stamp=if($Family -in @('desktop-run','desktop-verification')){$time.ToString('yyyyMMdd-HHmmss')+'-01234567'}else{$time.ToString('yyyyMMddTHHmmssfffffffZ')}
    $path=Join-Path $work ('operations/'+$Family+'-'+$stamp)
    $null=New-Item -ItemType Directory -Path $path -Force
    if(-not $Record.Contains('finished_utc')){$Record.finished_utc=$time.ToString('o')}
    $marker=if($Family -eq 'components'){'components.json'}else{'receipt.json'}
    $Record|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $path $marker)
    (Get-Item -LiteralPath (Join-Path $path $marker)).LastWriteTimeUtc=$time
    return $path
}
try {
    $work=Join-Path $root 'work';$build=Join-Path $root 'build';$prefix=Join-Path $root 'modular';$iisRoot=Join-Path $root 'iis'
    $store=Join-Path $work 'artifacts/windows-components';$modular=[pscustomobject]@{prefix=$prefix;artifacts=$store;installed_config=(Join-Path $root 'installed.json')}
    $iis=[pscustomobject]@{directory=$iisRoot}
    $active=Fixture (Join-Path $prefix ('releases/'+('a'*64))) 'package.json' ('a'*64)
    $held=Fixture (Join-Path $prefix ('releases/'+('b'*64))) 'package.json' ('b'*64)
    $rollback=Fixture (Join-Path $prefix ('releases/'+('c'*64))) 'package.json' ('c'*64)
    $old=Fixture (Join-Path $prefix ('releases/'+('d'*64))) 'package.json' ('d'*64)
    $database=Fixture (Join-Path $prefix ('releases/'+('9'*64))) 'package.json' ('9'*64)
    (Get-Item -LiteralPath $old).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-3)
    $iisActive=Fixture (Join-Path $iisRoot ('web/releases/'+('e'*64))) 'iis-package.json' ('e'*64)
    $boot=Fixture (Join-Path $iisRoot ('web/releases/'+('f'*64))) 'iis-package.json' ('f'*64)
    $unknown=Join-Path $prefix 'releases/unowned';$null=New-Item -ItemType Directory -Path $unknown
    @{release=$active} | ConvertTo-Json | Set-Content -LiteralPath $modular.installed_config
    @{revision=('e'*64)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $iisRoot 'web/active.json')
    '<configuration><system.webServer><aspNetCore processPath=".\releases\'+('f'*64)+'\app.exe" /></system.webServer></configuration>' | Set-Content -LiteralPath (Join-Path $iisRoot 'web/web.config')
    $process=[pscustomobject]@{pid=21;name='lpm.exe';executable=(Join-Path $held 'test.exe');command='';modules=@();module_error=$false}
    $args=@{WorkRoot=$work;BuildRoot=$build;Modular=$modular;Iis=$iis;Processes=@($process);DatabaseReferences=@((Join-Path $database 'test.dll'));BuildReferences=@()}
    $uciRoot=Join-Path $root 'laplace-mono-uci'
    $uciActive=Fixture (Join-Path $uciRoot ('releases/'+('1'*64))) 'uci-package.json' ('1'*64)
    Set-Content -LiteralPath (Join-Path $uciActive 'laplace-uci-connect.exe') 'fixture'
    $uciPinned=Fixture (Join-Path $uciRoot ('releases/'+('2'*64))) 'uci-package.json' ('2'*64)
    $uciRollback=Fixture (Join-Path $uciRoot ('releases/'+('3'*64))) 'uci-package.json' ('3'*64)
    $uciOld=Fixture (Join-Path $uciRoot ('releases/'+('4'*64))) 'uci-package.json' ('4'*64)
    (Get-Item -LiteralPath $uciOld).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-4)
    $null=New-Item -ItemType Directory -Path (Join-Path $uciRoot 'agent')
    @{host=$env:COMPUTERNAME;site='laplace-mono-uci';directory=$uciRoot;revision=('1'*64);publish=$uciActive}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $uciRoot 'agent/installation.json')
    $iis|Add-Member chess @{match_engines=@{connector=(Join-Path $uciPinned 'test.dll')}}
    $uciLegacy=Join-Path $uciRoot 'releases/legacy-build'
    $null=New-Item -ItemType Directory -Path $uciLegacy
    foreach($file in 'laplace-uci-connect.exe','laplace-uci-connect.dll'){Set-Content -LiteralPath (Join-Path $uciLegacy $file) 'legacy fixture'}
    $configuration='serve --configuration "'+(Join-Path $uciRoot 'connector.json')+'"'
    ('<configuration><system.webServer><aspNetCore processPath=".\laplace-uci-connect.exe" arguments="'+[Security.SecurityElement]::Escape($configuration)+'" /></system.webServer></configuration>')|Set-Content -LiteralPath (Join-Path $uciLegacy 'web.config')
    $digest=Get-StorageUciPayload $uciLegacy
    Rename-Item -LiteralPath $uciLegacy -NewName $digest
    $uciLegacy=Join-Path $uciRoot ('releases/'+$digest)
    (Get-Item -LiteralPath $uciLegacy).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-5)
    $plan=Get-DesktopStoragePlan @args
    Require ($plan.entries|Where-Object {$_.path -eq $uciLegacy -and $_.retire}) 'A verified older UCI payload was not selected.'
    $legacyEntry=$plan.entries|Where-Object path -EQ $uciLegacy
    Add-Content -LiteralPath (Join-Path $uciLegacy 'laplace-uci-connect.dll') 'changed after audit'
    $refused=$false;try{Remove-StorageEntry $legacyEntry}catch{$refused=$true}
    Require ($refused -and (Test-Path -LiteralPath $uciLegacy)) 'Modified UCI bytes were retired using an old digest.'
    Set-Content -LiteralPath (Join-Path $uciLegacy 'laplace-uci-connect.dll') 'legacy fixture'
    Require ($plan.entries|Where-Object {$_.path -eq $uciOld -and $_.retire}) 'Unused UCI release was not selected.'
    foreach($path in $uciActive,$uciPinned,$uciRollback){Require (-not ($plan.entries|Where-Object path -EQ $path).retire) 'A selected, pinned or rollback UCI release was retired.'}
    $args.Processes+=@(1,2|ForEach-Object {[pscustomobject]@{pid=(100+$_);name='w3wp.exe';executable='w3wp.exe';command='w3wp.exe -ap "laplace-mono-uci"';modules=@();module_error=$false}})
    $overlap=Get-DesktopStoragePlan @args
    Require (-not ($overlap.entries|Where-Object path -EQ $uciOld).retire) 'An overlapped UCI worker lost its managed assembly.'
    $args.Processes=@($process)
    $uciLock=[IO.File]::Open((Join-Path $uciRoot '.publication.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $refused=$false;try{Invoke-DesktopStorageCleanup @args|Out-Null}catch{$refused=$true}
        Require ($refused -and (Test-Path -LiteralPath $uciLegacy)) 'Cleanup raced a connector publication.'
    }finally{$uciLock.Dispose()}
    Require (-not ($plan.entries | Where-Object path -EQ $active).retire) 'Active modular release was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $held).retire) 'Running old release was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $database).retire) 'Database cache reference was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $rollback).retire) 'Rollback release was retired.'
    Require ($plan.entries | Where-Object { $_.path -eq $old -and $_.retire }) 'Unused old release was not retired.'
    $consumer=Join-Path $root 'modular-web'
    $consumerCurrent=Join-Path $consumer 'releases/current'
    $consumerPrevious=Join-Path $consumer 'releases/previous'
    $null=New-Item -ItemType Directory -Force -Path $consumerCurrent,$consumerPrevious,(Join-Path $consumer 'state')
    @{directory=$consumerCurrent;previous=$consumerPrevious}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $consumer 'active.json')
    @{release=$old}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $consumerCurrent 'native-resources.json')
    @{release=$held}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $consumerPrevious 'native-resources.json')
    $script:webReferenceFixture=Join-Path $root 'modular-web.json'
    @{directory=$consumer}|ConvertTo-Json|Set-Content -LiteralPath $script:webReferenceFixture
    $consumerPlan=Get-DesktopStoragePlan @args
    Require (-not ($consumerPlan.entries|Where-Object path -EQ $old).retire) 'The modular browser lost its selected native resources.'
    Require (@(Get-StorageModularWebReferences) -contains $held) 'The modular browser rollback lost its native resources.'
    $script:webReferenceFixture=''
    Require (-not ($plan.entries | Where-Object path -EQ $boot).retire) 'web.config selection was retired while active.json lagged.'
    Require (-not ($plan.entries | Where-Object path -EQ $unknown)) 'Unowned directory was classified as a package.'
    $args.Processes=@([pscustomobject]@{pid=22;name='lpm.exe';executable=$null;command='';modules=@();module_error=$false})
    Require (-not ((Get-DesktopStoragePlan @args).entries | Where-Object {$_.retire -and $_.kind -eq 'modular_release'})) 'Incomplete native process visibility permitted modular release retirement.'
    $args.Processes=@([pscustomobject]@{pid=23;name='w3wp.exe';executable=$null;command='';modules=@();module_error=$true})
    Require (-not ((Get-DesktopStoragePlan @args).entries | Where-Object {$_.retire -and $_.kind -in @('iis_release','uci_release')})) 'Incomplete IIS visibility permitted managed release retirement.'
    $outside=Join-Path $root 'outside';$null=New-Item -ItemType Directory -Path $outside
    Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
    $link=Join-Path $old 'redirect';$null=New-Item -ItemType Junction -Path $link -Target $outside
    $rejected=$false;try{Assert-StorageTree $old (Split-Path -Parent $old)}catch{$rejected=$true}
    Require $rejected 'A directory junction was accepted for recursive retirement.'
    Require (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'Junction target was modified.'
    Remove-Item -LiteralPath $link -Force
    (Get-Item -LiteralPath $old).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-3)
    $rejected=$false;try{Assert-StorageTree $outside (Split-Path -Parent $old)}catch{$rejected=$true}
    Require $rejected 'A path outside its owning directory was accepted.'
    $null=New-Item -ItemType Directory -Path (Join-Path $store 'blobs/11') -Force
    $orphan=Join-Path $store ('blobs/11/'+('1'*64))
    $shared=Join-Path $store ('blobs/11/11'+('2'*62))
    Set-Content -LiteralPath $orphan -Value 'orphan'
    Set-Content -LiteralPath $shared -Value 'shared'
    $null=New-Item -ItemType HardLink -Path (Join-Path $active 'shared.dll') -Target $shared
    Require ((Get-StorageLinkCount $orphan) -eq 1) 'Orphan blob link count is wrong.'
    Require ((Get-StorageLinkCount $shared) -eq 2) 'Shared blob link count is wrong.'
    $legacy=Join-Path $work ('iis-packages/'+('3'*40)+'-'+('4'*32)+'/published')
    $null=New-Item -ItemType Directory -Path $legacy -Force
    Set-Content -LiteralPath (Join-Path $legacy 'incomplete.dll') -Value 'failed build'
    $args.Processes=@($process)
    $lock=[IO.File]::Open((Join-Path $store '.build.lock'),'OpenOrCreate','ReadWrite','None')
    try {
        $rejected=$false;try{Invoke-DesktopStorageCleanup @args}catch{$rejected=$true}
        Require $rejected 'Cleanup ignored a held component-store lock.'
        Require (Test-Path -LiteralPath $old) 'Lock refusal changed an old release.'
    }finally{$lock.Dispose()}
    Require (-not (Test-StoragePublisher ([pscustomobject]@{name='pwsh.exe';command='pwsh.exe -NoProfile -Command "Get-Content Build-IisPackage.ps1"'}))) 'A source inspection was mistaken for a publisher.'
    Require (Test-StoragePublisher ([pscustomobject]@{name='pwsh.exe';command='pwsh.exe -NoProfile -File "C:\source with spaces\Build-IisPackage.ps1"'})) 'A direct publisher with a quoted path was missed.'
    $args.Processes=@($process,[pscustomobject]@{pid=23;name='python.exe';executable='python.exe';command='python.exe package-windows-client.py';modules=@();module_error=$false})
    $rejected=$false;try{Invoke-DesktopStorageCleanup @args}catch{$rejected=$true}
    Require $rejected 'Cleanup ignored an active publisher.'
    Require (Test-Path -LiteralPath $old) 'Publisher refusal changed an old release.'
    $args.Processes=@($process)
    $abandoned=Join-Path $build 'worktrees/wt-retired-0123456789ab'
    $source=Join-Path $build 'worktrees/wt-source-0123456789ab'
    $null=New-Item -ItemType Directory -Path $abandoned,(Join-Path $source '.git') -Force
    $testRun=Join-Path $work 'operations/test-20261029T0000000000000Z'
    $testReceipt=Join-Path $testRun 'receipt.json'
    foreach ($case in @(@{check='expired';owner=424242;child=0},@{check='running';owner=21;child=0},@{check='finishing';owner=424242;child=424243})) {
        $scratch=Join-Path $testRun ($case.check+'-scratch')
        $null=New-Item -ItemType Directory -Path $scratch -Force
        @{schema='laplace.acceptance-scratch/v1';owner_pid=$case.owner;child_pid=$case.child;receipt=$testReceipt;check=$case.check}|ConvertTo-Json|Set-Content (Join-Path $scratch '.laplace-scratch.json')
    }
    Set-Content $testReceipt 'retained evidence'
    $args.Processes+=@([pscustomobject]@{pid=77;parent_pid=424243;name='python.exe';executable='python.exe';command='';modules=@();module_error=$false},
        [pscustomobject]@{pid=4;parent_pid=0;name='System';executable=$null;command='';modules=@();module_error=$false})
    $dbHistory=@(1..12|ForEach-Object {HistoryFixture 'iis-database' $_ @{host='desktop';database='substrate';operation='status';completed=$true}})
    $modularHistory=@(41..44|ForEach-Object {HistoryFixture 'modular-database' $_ @{host='desktop';database='laplace';operation='recreate';completed=$true}})
    $dbFailures=@(20..21|ForEach-Object {HistoryFixture 'iis-database' $_ @{host='desktop';database='substrate';operation='status';completed=$false}})
    $otherTarget=HistoryFixture 'iis-database' 0 @{host='other-host';database='substrate';operation='status';completed=$true}
    $args.Processes+=@([pscustomobject]@{pid=78;parent_pid=0;name='reader.exe';executable=(Join-Path $dbHistory[0] 'reader.exe');command='';modules=@();module_error=$false})
    Set-Content -LiteralPath (Join-Path $dbHistory[1] '.retain') -Value 'operator retained'
    $null=New-Item -ItemType Directory -Path (Join-Path $dbHistory[3] '.git')
    $deployHistory=HistoryFixture 'desktop-deploy' 30 @{operation='deploy';target='desktop';status='passed';cleanup=@{receipt=(Join-Path $dbHistory[2] 'receipt.json')}}
    $storageHistory=@(1..4|ForEach-Object {
        $path=Join-Path $work ('operations/storage-20200101T000'+$_+'000000000Z.json')
        @{status='passed';finished_utc=[DateTime]::new(2020,1,1).AddMinutes($_).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $path
        $path
    })
    $linked=Read-StorageJson (Join-Path $dbHistory[2] 'receipt.json')
    $linked|Add-Member NoteProperty cleanup @{receipt=$storageHistory[0]}
    $linked|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $dbHistory[2] 'receipt.json')
    $testHistory=@(31..35|ForEach-Object {HistoryFixture 'test' $_ @{schema_version=1;completed_utc=[DateTime]::new(2020,1,1).AddMinutes($_).ToString('o');selected_checks_verdict='passed';checks=@(@{check='fixture';status='passed'})}})
    $scratch=Join-Path $testHistory[0] 'fixture-scratch'
    $null=New-Item -ItemType Directory -Path $scratch
    @{schema='laplace.acceptance-scratch/v1';owner_pid=21;child_pid=0;receipt=(Join-Path $testHistory[0] 'receipt.json');check='fixture'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $scratch '.laplace-scratch.json')
    $unfinished=HistoryFixture 'desktop-deploy' 36 @{operation='deploy';target='desktop';status='failed';finished_utc=$null}
    $malformed=HistoryFixture 'desktop-deploy' 37 @{operation='deploy';target='desktop';status='passed'}
    Set-Content -LiteralPath (Join-Path $malformed 'receipt.json') -Value 'unfinished JSON {'
    $zoneHistory=@(41..44|ForEach-Object {HistoryFixture 'desktop-deploy' $_ @{operation='deploy';target='timezone-regression';status='passed';finished_utc=[DateTime]::UtcNow.AddHours(-1).AddSeconds($_).ToString('o')}})
    $runHistory=@(50..54|ForEach-Object {HistoryFixture 'desktop-run' $_ @{source='E:/source';build_root=$build;base_url='http://localhost:5187';status='verified'}})
    $verification=HistoryFixture 'desktop-verification' 55 @{source='E:/source';url='http://localhost:5187';status='verified';run_directory=$runHistory[0]}
    $historyPlan=Get-DesktopStoragePlan @args
    Require ($historyPlan.entries|Where-Object {$_.path -eq $modularHistory[0] -and $_.retire}) 'Installed database operation history was not bounded.'
    Require ($historyPlan.entries|Where-Object {$_.path -eq $zoneHistory[0] -and $_.retire}) 'UTC completion times were shifted into the future by JSON date conversion.'
    Require (-not ($historyPlan.entries|Where-Object path -EQ $runHistory[0]).retire) 'Retained verification lost its original run.'
    Require ($historyPlan.entries|Where-Object {$_.path -eq $runHistory[1] -and $_.retire}) 'Completed development run histories were unbounded.'
    foreach($kept in @($dbHistory[0],$dbHistory[1],$dbHistory[2],$dbHistory[3],$dbHistory[9],$dbHistory[10],$dbHistory[11],$dbFailures[1],$otherTarget,$testHistory[0],$storageHistory[0])) {
        Require (-not ($historyPlan.entries|Where-Object path -EQ $kept).retire) "Protected operation history was selected: $kept"
    }
    foreach($retired in @($dbHistory[4],$dbHistory[5],$dbHistory[6],$dbHistory[7],$dbHistory[8],$dbFailures[0],$testHistory[1],$storageHistory[1])) {
        Require ($historyPlan.entries|Where-Object {$_.path -eq $retired -and $_.retire}) "Superseded operation history was not selected: $retired"
    }
    Require (-not ($historyPlan.entries|Where-Object {$_.path -in @($unfinished,$malformed)})) 'Incomplete receipts established deletion ownership.'
    # Receipt edits between audit and collection invalidate the deletion decision.
    $changed=$historyPlan.entries|Where-Object path -EQ $dbHistory[4]
    Add-Content -LiteralPath $changed.receipt_path -Value ' '
    $rejected=$false;try{Remove-StorageEntry $changed}catch{$rejected=$true}
    Require ($rejected -and (Test-Path -LiteralPath $changed.path)) 'A changed receipt did not invalidate retirement.'
    $pinned=$historyPlan.entries|Where-Object path -EQ $dbHistory[5]
    Set-Content -LiteralPath (Join-Path $pinned.path '.retain') -Value 'new operator pin'
    $rejected=$false;try{Remove-StorageEntry $pinned}catch{$rejected=$true}
    Require ($rejected -and (Test-Path -LiteralPath $pinned.path)) 'An operator pin added after the audit did not invalidate retirement.'
    $scratchPlan=Get-DesktopStoragePlan @args
    Require ($scratchPlan.entries | Where-Object {$_.path -eq (Join-Path $testRun 'expired-scratch') -and $_.retire}) 'Expired owned test payload was not selected.'
    Require (-not ($scratchPlan.entries | Where-Object path -EQ (Join-Path $testRun 'running-scratch')).retire) 'Running test payload was selected.'
    $clean=Invoke-DesktopStorageCleanup @args
    Require (-not (Test-Path (Join-Path $testRun 'expired-scratch'))) 'Expired test payload survived canonical cleanup.'
    Require (Test-Path (Join-Path $testRun 'running-scratch')) 'Running test payload was deleted.'
    Require (Test-Path (Join-Path $testRun 'finishing-scratch')) 'A surviving child lost its payload after its runner exited.'
    Require (Test-Path $testReceipt) 'Cleanup deleted test evidence.'
    foreach($retired in @($dbHistory[4],$dbFailures[0],$testHistory[1],$storageHistory[1])) {
        Require (-not (Test-Path -LiteralPath $retired)) "Canonical cleanup left superseded history: $retired"
    }
    foreach($kept in @($dbHistory[0],$dbHistory[1],$dbHistory[2],$dbHistory[3],$dbHistory[9],$dbFailures[1],$otherTarget,$testHistory[0],$unfinished,$malformed,$storageHistory[0])) {
        Require (Test-Path -LiteralPath $kept) "Canonical cleanup removed protected history: $kept"
    }
    Require ($clean.status -eq 'passed') 'Cleanup did not pass.'
    Require (-not (Test-Path -LiteralPath $old)) 'Unused old release survived collection.'
    Require (-not (Test-Path -LiteralPath $uciOld)) 'Unused UCI release survived canonical collection.'
    Require (-not (Test-Path -LiteralPath $uciLegacy)) 'Verified older UCI payload survived canonical collection.'
    foreach($path in $uciActive,$uciPinned,$uciRollback){Require (Test-Path -LiteralPath $path) 'UCI consumer or rollback release disappeared.'}
    Require (-not (Test-Path -LiteralPath $legacy)) 'Incomplete legacy payload survived collection.'
    Require (-not (Test-Path -LiteralPath $orphan)) 'Unlinked blob survived collection.'
    Require (-not (Test-Path -LiteralPath $abandoned)) 'Abandoned generated worktree build survived collection.'
    foreach($kept in @($active,$held,$rollback,$database,$iisActive,$boot,$shared,$unknown,$source)) {
        Require (Test-Path -LiteralPath $kept) "Protected path disappeared: $kept"
    }
    $receipt=Read-StorageJson $clean.receipt
    Require ($receipt.status -eq 'passed' -and $receipt.removed -contains $old) 'Cleanup receipt is incomplete.'
    $again=Invoke-DesktopStorageCleanup @args
    Require ($again.removed.Count -eq 0) 'Repeated cleanup was not idempotent.'
    # Normal test/database completion uses the same history owner without
    # requiring installed releases or running the database collector.
    $extra=HistoryFixture 'iis-database' 40 @{host='desktop';database='substrate';operation='status';completed=$true}
    Invoke-OperationHistoryCleanup -WorkRoot $work -Processes $args.Processes
    Require (-not (Test-Path -LiteralPath $dbHistory[9])) 'Normal operation exit did not bound completed history.'
    Require (Test-Path -LiteralPath $extra) 'History cleanup removed the latest completed operation.'
    $failedOutput=Fixture (Join-Path $prefix ('releases/'+('8'*64))) 'package.json' ('8'*64)
    (Get-Item -LiteralPath $failedOutput).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-5)
    $operation=Enter-DesktopStorageOperation $work
    Require ($null -eq (Enter-DesktopStorageOperation $work)) 'A nested publisher did not share its owner lock.'
    $originalFailure=$false
    try { try { throw 'fixture publisher failed' } finally { Exit-DesktopStorageOperation -Operation $operation @args } }
    catch { $originalFailure=$_.Exception.Message -eq 'fixture publisher failed' }
    Require $originalFailure 'Automatic cleanup replaced the original publisher failure.'
    Require (-not (Test-Path -LiteralPath $failedOutput)) 'Failed operation did not collect in its finally block.'
    Require ($env:LAPLACE_STORAGE_OWNER_PID -eq $initialOwner) 'Operation ownership leaked after cleanup.'
    'Storage: references, rollback, visibility, path bounds, locks, hardlinks, bounded success/failure histories, live owners, PID zero, linked receipts, changed receipts, idempotence and finally cleanup passed.'
} finally {
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')) { throw 'Invalid fixture cleanup root.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
