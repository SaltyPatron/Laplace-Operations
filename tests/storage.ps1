#Requires -Version 7
$ErrorActionPreference='Stop'
$initialOwner=$env:LAPLACE_STORAGE_OWNER_PID
. "$PSScriptRoot/../installation/storage.ps1"
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
    $plan=Get-DesktopStoragePlan @args
    Require (-not ($plan.entries | Where-Object path -EQ $active).retire) 'Active modular release was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $held).retire) 'Running old release was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $database).retire) 'Database cache reference was retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $rollback).retire) 'Rollback release was retired.'
    Require ($plan.entries | Where-Object { $_.path -eq $old -and $_.retire }) 'Unused old release was not retired.'
    Require (-not ($plan.entries | Where-Object path -EQ $boot).retire) 'web.config selection was retired while active.json lagged.'
    Require (-not ($plan.entries | Where-Object path -EQ $unknown)) 'Unowned directory was classified as a package.'
    $args.Processes=@([pscustomobject]@{pid=22;name='lpm.exe';executable=$null;command='';modules=@();module_error=$false})
    Require (-not ((Get-DesktopStoragePlan @args).entries | Where-Object retire)) 'Incomplete process visibility permitted release retirement.'
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
    $clean=Invoke-DesktopStorageCleanup @args
    Require ($clean.status -eq 'passed') 'Cleanup did not pass.'
    Require (-not (Test-Path -LiteralPath $old)) 'Unused old release survived collection.'
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
    'Storage: references, rollback, visibility, path bounds, locks, failed payloads, hardlinks, receipts, idempotence and nested/failing operation cleanup passed.'
} finally {
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')) { throw 'Invalid fixture cleanup root.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
