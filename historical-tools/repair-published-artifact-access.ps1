#Requires -Version 7
[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$audit=$PSScriptRoot
$workspace='E:\Repositories\Laplace'
$operations=Join-Path $workspace 'Laplace-Operations'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$operator=Get-Content -LiteralPath (Join-Path $operations 'installation/hart-desktop-operator.json') -Raw|ConvertFrom-Json
if($identity.User.Value -ne $operator.windows_sid){throw 'Use the enrolled Windows operator identity.'}
$installed=Get-Content -LiteralPath (Join-Path $audit 'desktop-all-installed-readback.json') -Raw|ConvertFrom-Json
$floor=Get-Content -LiteralPath (Join-Path $audit 'desktop-codepoint-runtime-readback-final.json') -Raw|ConvertFrom-Json
if(-not $installed.passed -or $floor.status -ne 'passed'){throw 'Installed runtime qualification must already have passed.'}
$targets=@(Get-Content -LiteralPath (Join-Path $audit 'desktop-new-published-access-repair-targets.json') -Raw|ConvertFrom-Json)
$store='E:\Data\Laplace\work\artifacts\windows-components'
$expected=@(
    'api\944afe35fdc8d7cc292e2eb8872fae2c251a6d9a4363d56b0dbb2a69c35127f0',
    'cli\873385e5998d7f9fed907a28795866b75e468148aa6c445b1c26b7ceb51bab24',
    'uci\e78ee8c68000cf6993bccd75c69a2ea17844a1798297ffa318d6401ad612e77e',
    'migrations\c8bf4ea1f3dae2d5fc6cd7a0bd72c7e7e7c537135b068c8e7ee1196ddbbca803'
)|ForEach-Object {Join-Path $store $_}
if($targets.Count -ne 4 -or @(Compare-Object @($targets.path|Sort-Object) @($expected|Sort-Object)).Count){
    throw 'The access-repair target set changed.'
}
foreach($target in $targets){
    $path=[IO.Path]::GetFullPath($target.path)
    if($path -notmatch ('^'+[regex]::Escape($store)+'\\(?:api|cli|uci|migrations)\\[a-f0-9]{64}$')){
        throw 'An access-repair target escaped the component store.'
    }
    if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){
        throw 'Access repair must not follow a reparse point.'
    }
}
$administrator=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($PreflightOnly){
    [ordered]@{status='preflight-passed';checked_utc=[DateTime]::UtcNow.ToString('o');
        targets=@($targets.path);administrator_token=$administrator;runtime_already_verified=$true;
        builds_or_installations=0;action='Grant enrolled operator access on four published components, then run standard cleanup.'}|ConvertTo-Json
    exit 0
}
if(-not $administrator){throw 'Existing private component ACLs require an Administrator token; this script requests no elevation.'}
$receipt=[ordered]@{status='running';started_utc=[DateTime]::UtcNow.ToString('o');
    identity=$identity.Name;repaired=@();builds_or_installations=0}
$receiptPath=Join-Path $audit 'desktop-published-access-repair-completion.json'
function Save {$receipt|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $receiptPath -Encoding utf8}
Save
try{
    foreach($target in $targets){
        $path=[IO.Path]::GetFullPath($target.path)
        $items=@(Get-Item -LiteralPath $path -Force)+@(Get-ChildItem -LiteralPath $path -Recurse -Force)
        if(@($items|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'A component contains a reparse point.'}
        foreach($item in $items){
            $acl=Get-Acl -LiteralPath $item.FullName
            $flags=if($item.PSIsContainer){'ContainerInherit,ObjectInherit'}else{'None'}
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($operator.windows_sid),'FullControl',$flags,'None','Allow'))
            Set-Acl -LiteralPath $item.FullName -AclObject $acl
        }
        $receipt.repaired+=@{path=$path;items=$items.Count};Save
    }
    $output=@(& pwsh -NoProfile -File (Join-Path $operations 'laplace.ps1') storage clean -Target desktop -Json)
    if($LASTEXITCODE){throw "Standard storage cleanup failed: $LASTEXITCODE"}
    $cleanup=($output -join "`n")|ConvertFrom-Json
    if($cleanup.status -ne 'passed'){throw 'Storage cleanup did not return a passed receipt.'}
    $output|Set-Content -LiteralPath (Join-Path $audit 'desktop-storage-cleanup-final.json') -Encoding utf8
    $receipt.cleanup_receipt=$cleanup.receipt;$receipt.removed=$cleanup.removed.Count
    $receipt.status='passed';$receipt.completed_utc=[DateTime]::UtcNow.ToString('o');Save
}catch{
    $receipt.status='failed';$receipt.error=$_.Exception.Message;Save
    throw
}
